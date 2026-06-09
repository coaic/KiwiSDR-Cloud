#!/usr/bin/env bash
# submit-build.sh — submit one KiwiSDR Vivado build as a Cloud Batch job.
#
# Usage:   ./submit-build.sh <git-url> [git-ref] [rx-config]
# Example: ./submit-build.sh https://github.com/coaic/KiwiSDR.git master rx44
#
# rx-config: rx44 (default), rx82, rx33, rx14
#            Omit to build all 4 configs sequentially in one job.
#
# Prerequisites:
#   export GCP_PROJECT=kiwisdr-fpga-builds
#   gcloud auth application-default login

set -euo pipefail

PROJECT_ID="${GCP_PROJECT:?set GCP_PROJECT env var}"
REGION="${GCP_REGION:-australia-southeast1}"
GIT_REPO="${1:?usage: submit-build.sh <git-url> [git-ref] [rx-config]}"
GIT_REF="${2:-master}"
RX_CFG="${3:-all}"

JOB_NAME="kiwisdr-$(date +%Y%m%d-%H%M%S)"
BUCKET="${PROJECT_ID}-fpga-artifacts"
SA_EMAIL="fpga-builder@${PROJECT_ID}.iam.gserviceaccount.com"
IMAGE_URI="projects/${PROJECT_ID}/global/images/family/vivado-kiwisdr"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_SCRIPT="${SCRIPT_DIR}/patch_make_proj.py"
PATCH_GCS="gs://${BUCKET}/tools/patch_make_proj.py"

case "${RX_CFG}" in
  rx44) TCL_FLAG="--rx4_wf4" ;;
  rx82) TCL_FLAG="--rx8_wf2" ;;
  rx33) TCL_FLAG="--rx3_wf3" ;;
  rx14) TCL_FLAG="--rx14_wf0" ;;
  all)  TCL_FLAG="" ;;
  *)    echo "Unknown rx-config: ${RX_CFG}. Use rx44, rx82, rx33, rx14, or all."; exit 1 ;;
esac

# Upload patch script to GCS so the build VM can download it.
# Uploaded every submission so the VM always runs the current version.
echo "Uploading patch_make_proj.py -> ${PATCH_GCS}"
gsutil cp "${PATCH_SCRIPT}" "${PATCH_GCS}"

# ---- Build script that runs on the VM ----------------------------------------

read -r -d '' BUILD_SCRIPT <<EOF || true
#!/bin/bash
set -e
exec > >(tee /var/log/build.log) 2>&1

export HOME=/root

gcs_token() {
  curl -sf \
    -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}

gcs_upload() {
  local src="\$1" dst="\$2"
  local object
  object=\$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "\${dst}")
  curl -sf -X POST \
    -H "Authorization: Bearer \$(gcs_token)" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@\${src}" \
    "https://storage.googleapis.com/upload/storage/v1/b/${BUCKET}/o?uploadType=media&name=\${object}" \
    > /dev/null && echo "Uploaded \${src} -> gs://${BUCKET}/\${dst}" || echo "WARNING: upload failed for \${src}"
}

gcs_download() {
  local src="\$1" dst="\$2"
  local object
  object=\$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "\${src}")
  curl -sf \
    -H "Authorization: Bearer \$(gcs_token)" \
    "https://storage.googleapis.com/storage/v1/b/${BUCKET}/o/\${object}?alt=media" \
    -o "\${dst}" && echo "Downloaded gs://${BUCKET}/\${src} -> \${dst}"
}

# Always upload log on exit, even if the script fails early
trap 'gcs_upload /var/log/build.log "${JOB_NAME}/build.log"' EXIT

echo "=== KiwiSDR build: repo=${GIT_REPO} ref=${GIT_REF} cfg=${RX_CFG} ==="

# Download patch script from GCS (curl, no gsutil dependency)
gcs_download "tools/patch_make_proj.py" /tmp/patch_make_proj.py

cd /tmp
rm -rf project
git clone --depth=1 --branch "${GIT_REF}" "${GIT_REPO}" project

rm -rf /build && mkdir -p /build/KiwiSDR/import_srcs /build/KiwiSDR/import_ip /build/generated
rsync -a /tmp/project/verilog/ /build/KiwiSDR/import_srcs/
rsync -a /tmp/project/verilog.Vivado.2022.2.ip/ /build/KiwiSDR/import_ip/
cp /tmp/project/verilog/kiwi.tcl /tmp/project/verilog/make_proj.tcl /build/

# Patch 1: -force flag so create_project tolerates the pre-restored IP cache dir
sed -i 's/create_project \\\${project_name} \\.\/\\\${project_name}/create_project -force \\\${project_name} .\\/\\\${project_name}/' /build/make_proj.tcl

# Patch 2: inject IP XCI import block — see docs/vivado-batch-ip-handling.md
python3 /tmp/patch_make_proj.py /build/make_proj.tcl

# IP cache disabled: the baked cache was compiled under Vivado 2022.2 and
# conflicts with the 2022.2 XCIs upgraded to 2024.2 at import time.
# IPs compile fresh from the upgraded XCIs (~30 min extra, first build only).

source /tools/Xilinx/Vivado/2024.2/settings64.sh

cd /build
time vivado -mode batch -source make_proj.tcl \\
  -tclargs --result_dir /build ${TCL_FLAG} || BUILD_FAILED=1

gcs_upload /var/log/build.log "${JOB_NAME}/build.log"
for f in /build/KiwiSDR.*.bit; do
  [ -f "\$f" ] && gcs_upload "\$f" "${JOB_NAME}/\$(basename \$f)"
done

[ -z "\${BUILD_FAILED:-}" ]
EOF

SCRIPT_JSON=$(printf '%s' "${BUILD_SCRIPT}" | jq -Rs .)

CONFIG=$(cat <<EOF
{
  "taskGroups": [{
    "taskSpec": {
      "runnables": [{ "script": { "text": ${SCRIPT_JSON} } }],
      "computeResource": { "cpuMilli": 8000, "memoryMib": 32768 },
      "maxRetryCount": 1,
      "maxRunDuration": "14400s"
    },
    "taskCount": 1,
    "parallelism": 1
  }],
  "allocationPolicy": {
    "instances": [{
      "policy": {
        "machineType": "n2-standard-8",
        "provisioningModel": "SPOT",
        "bootDisk": {
          "image": "${IMAGE_URI}",
          "type": "pd-standard",
          "sizeGb": 400
        }
      }
    }],
    "serviceAccount": {
      "email": "${SA_EMAIL}",
      "scopes": ["https://www.googleapis.com/auth/cloud-platform"]
    },
    "network": {
      "networkInterfaces": [{
        "network": "global/networks/default",
        "subnetwork": "regions/${REGION}/subnetworks/default",
        "noExternalIpAddress": true
      }]
    },
    "labels": { "workload": "kiwisdr-build" }
  },
  "logsPolicy": { "destination": "CLOUD_LOGGING" }
}
EOF
)

echo "Submitting Batch job ${JOB_NAME} (cfg=${RX_CFG})..."
echo "${CONFIG}" | gcloud batch jobs submit "${JOB_NAME}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --config=-

echo
echo "Useful commands:"
echo "  Status:  gcloud batch jobs describe ${JOB_NAME} --location=${REGION} --project=${PROJECT_ID}"
echo "  Logs:    gcloud logging read 'resource.type=batch.googleapis.com/Job AND labels.job_uid:${JOB_NAME}' --limit=100 --project=${PROJECT_ID}"
echo "  Fetch:   gsutil cp 'gs://${BUCKET}/${JOB_NAME}/*.bit' ./"
echo "  Console: https://console.cloud.google.com/batch/jobsDetail/regions/${REGION}/jobs/${JOB_NAME}?project=${PROJECT_ID}"

#!/usr/bin/env bash
# submit-all-configs.sh — build all 4 KiwiSDR bitstream configurations.
#
# Submits rx44, rx82, rx33, rx14 as a single Cloud Batch job with 4 tasks
# running 2 at a time (parallelism capped to stay within the pd-standard
# 1000 GB regional quota — each task needs a 300 GB boot disk).
#
# Usage:   ./submit-all-configs.sh <git-url> [git-ref]
# Example: ./submit-all-configs.sh https://github.com/coaic/KiwiSDR.git master
#
# Prerequisites:
#   export GCP_PROJECT=kiwisdr-fpga-builds
#   gcloud auth application-default login

set -euo pipefail

PROJECT_ID="${GCP_PROJECT:?set GCP_PROJECT env var}"
REGION="${GCP_REGION:-australia-southeast1}"
GIT_REPO="${1:?usage: submit-all-configs.sh <git-url> [git-ref]}"
GIT_REF="${2:-master}"

JOB_NAME="kiwisdr-all-$(date +%Y%m%d-%H%M%S)"
BUCKET="${PROJECT_ID}-fpga-artifacts"
SA_EMAIL="fpga-builder@${PROJECT_ID}.iam.gserviceaccount.com"
IMAGE_URI="projects/${PROJECT_ID}/global/images/family/vivado-kiwisdr"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_SCRIPT="${SCRIPT_DIR}/patch_make_proj.py"
PATCH_GCS="gs://${BUCKET}/tools/patch_make_proj.py"

echo "Uploading patch_make_proj.py -> ${PATCH_GCS}"
gsutil cp "${PATCH_SCRIPT}" "${PATCH_GCS}"

# BATCH_TASK_INDEX (0-3) selects the config for each task.
# Single-quoted heredoc — no bash expansion; BATCH_TASK_INDEX resolved by
# the Batch agent at runtime.
read -r -d '' BUILD_SCRIPT_HEAD <<'BSEOF' || true
#!/bin/bash
set -e
exec > >(tee /var/log/build.log) 2>&1

export HOME=/root

CONFIGS=(rx44   rx82   rx33    rx14)
FLAGS=(--rx4_wf4 --rx8_wf2 --rx3_wf3 --rx14_wf0)

RX_CFG="${CONFIGS[$BATCH_TASK_INDEX]}"
TCL_FLAG="${FLAGS[$BATCH_TASK_INDEX]}"

gcs_token() {
  curl -sf \
    -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}

gcs_upload() {
  local src="$1" dst="$2"
  local object
  object=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "${dst}")
  curl -sf -X POST \
    -H "Authorization: Bearer $(gcs_token)" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@${src}" \
    "https://storage.googleapis.com/upload/storage/v1/b/BUCKET_PLACEHOLDER/o?uploadType=media&name=${object}" \
    > /dev/null && echo "Uploaded ${src} -> gs://BUCKET_PLACEHOLDER/${dst}" || echo "WARNING: upload failed for ${src}"
}

gcs_download() {
  local src="$1" dst="$2"
  local object
  object=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "${src}")
  curl -sf \
    -H "Authorization: Bearer $(gcs_token)" \
    "https://storage.googleapis.com/storage/v1/b/BUCKET_PLACEHOLDER/o/${object}?alt=media" \
    -o "${dst}" && echo "Downloaded gs://BUCKET_PLACEHOLDER/${src} -> ${dst}"
}
BSEOF

# Double-quoted section — bash expands JOB_NAME, GIT_REF, GIT_REPO, BUCKET, PATCH_GCS
read -r -d '' BUILD_SCRIPT_TAIL <<EOF || true

trap 'gcs_upload /var/log/build.log "${JOB_NAME}/\${RX_CFG}/build.log"' EXIT

echo "=== KiwiSDR build: repo=${GIT_REPO} ref=${GIT_REF} cfg=\${RX_CFG} ==="

gcs_download "tools/patch_make_proj.py" /tmp/patch_make_proj.py

cd /tmp
rm -rf project
git clone --depth=1 --branch "${GIT_REF}" "${GIT_REPO}" project

rm -rf /build && mkdir -p /build/KiwiSDR/import_srcs /build/KiwiSDR/import_ip /build/generated
rsync -a /tmp/project/verilog/ /build/KiwiSDR/import_srcs/
rsync -a /tmp/project/verilog.Vivado.2022.2.ip/ /build/KiwiSDR/import_ip/
cp /tmp/project/verilog/kiwi.tcl /tmp/project/verilog/make_proj.tcl /build/

sed -i 's/create_project \\\${project_name} \\.\/\\\${project_name}/create_project -force \\\${project_name} .\\/\\\${project_name}/' /build/make_proj.tcl
python3 /tmp/patch_make_proj.py /build/make_proj.tcl

source /tools/Xilinx/Vivado/2024.2/settings64.sh

cd /build
time vivado -mode batch -source make_proj.tcl \\
  -tclargs --result_dir /build \${TCL_FLAG} || BUILD_FAILED=1

for f in /build/KiwiSDR.*.bit; do
  [ -f "\$f" ] && gcs_upload "\$f" "${JOB_NAME}/\${RX_CFG}/\$(basename \$f)"
done

[ -z "\${BUILD_FAILED:-}" ]
EOF

# Substitute bucket placeholder in the single-quoted section
BUILD_SCRIPT="${BUILD_SCRIPT_HEAD//BUCKET_PLACEHOLDER/${BUCKET}}${BUILD_SCRIPT_TAIL}"
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
    "taskCount": 4,
    "parallelism": 2
  }],
  "allocationPolicy": {
    "instances": [{
      "policy": {
        "machineType": "n2-standard-8",
        "provisioningModel": "SPOT",
        "bootDisk": {
          "image": "${IMAGE_URI}",
          "type": "pd-standard",
          "sizeGb": 300
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
    "labels": { "workload": "kiwisdr-all-configs" }
  },
  "logsPolicy": { "destination": "CLOUD_LOGGING" }
}
EOF
)

echo "Submitting ${JOB_NAME} (4 configs, parallelism 2)..."
echo "${CONFIG}" | gcloud batch jobs submit "${JOB_NAME}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --config=-

echo
echo "Artifacts will be at: gs://${BUCKET}/${JOB_NAME}/<config>/<file>.bit"
echo "Useful commands:"
echo "  Status:  gcloud batch jobs describe ${JOB_NAME} --location=${REGION} --project=${PROJECT_ID}"
echo "  Fetch:   gsutil cp -r 'gs://${BUCKET}/${JOB_NAME}/**/*.bit' ./"
echo "  Console: https://console.cloud.google.com/batch/jobsDetail/regions/${REGION}/jobs/${JOB_NAME}?project=${PROJECT_ID}"

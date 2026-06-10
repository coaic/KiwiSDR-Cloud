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

PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
JOB_NAME="kiwisdr-$(date +%Y%m%d-%H%M%S)"
BUCKET="${PROJECT_ID}-${PROJECT_NUMBER}-fpga-artifacts"
SA_EMAIL="fpga-builder@${PROJECT_ID}.iam.gserviceaccount.com"
IMAGE_URI="projects/${PROJECT_ID}/global/images/family/vivado-2024-2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_GCS="gs://${BUCKET}/tools/patch_make_proj.py"

case "${RX_CFG}" in
  rx44) TCL_FLAG="--rx4_wf4" ;;
  rx82) TCL_FLAG="--rx8_wf2" ;;
  rx33) TCL_FLAG="--rx3_wf3" ;;
  rx14) TCL_FLAG="--rx14_wf0" ;;
  all)  TCL_FLAG="" ;;
  *)    echo "Unknown rx-config: ${RX_CFG}. Use rx44, rx82, rx33, rx14, or all."; exit 1 ;;
esac

# Upload patch script — VM downloads it at runtime; always upload current version.
echo "Uploading patch_make_proj.py -> ${PATCH_GCS}"
gsutil cp "${SCRIPT_DIR}/patch_make_proj.py" "${PATCH_GCS}"

# Substitute @@MARKER@@ values into the task script, then JSON-encode for embedding.
BUILD_SCRIPT=$(sed \
  -e "s|@@BUCKET@@|${BUCKET}|g" \
  -e "s|@@JOB_NAME@@|${JOB_NAME}|g" \
  -e "s|@@GIT_REF@@|${GIT_REF}|g" \
  -e "s|@@GIT_REPO@@|${GIT_REPO}|g" \
  -e "s|@@RX_CFG@@|${RX_CFG}|g" \
  -e "s|@@TCL_FLAG@@|${TCL_FLAG}|g" \
  "${SCRIPT_DIR}/build-task.sh")
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

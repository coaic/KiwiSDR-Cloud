#!/usr/bin/env bash
# submit-all-configs.sh — build all 4 KiwiSDR bitstream configurations.
#
# Submits rx44, rx82, rx33, rx14 as a single Cloud Batch job with 4 tasks
# running 2 at a time (parallelism capped to stay within the pd-standard
# 1000 GB regional quota — each task needs a 400 GB boot disk, 2 × 400 = 800 GB).
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

PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
JOB_NAME="kiwisdr-all-$(date +%Y%m%d-%H%M%S)"
BUCKET="${PROJECT_ID}-${PROJECT_NUMBER}-fpga-artifacts"
SA_EMAIL="fpga-builder@${PROJECT_ID}.iam.gserviceaccount.com"
IMAGE_URI="projects/${PROJECT_ID}/global/images/family/vivado-2024-2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_GCS="gs://${BUCKET}/tools/patch_make_proj.py"

# Upload patch script — VM downloads it at runtime; always upload current version.
echo "Uploading patch_make_proj.py -> ${PATCH_GCS}"
gsutil cp "${SCRIPT_DIR}/patch_make_proj.py" "${PATCH_GCS}"

# Substitute @@MARKER@@ values into the task script, then JSON-encode for embedding.
BUILD_SCRIPT=$(sed \
  -e "s|@@BUCKET@@|${BUCKET}|g" \
  -e "s|@@JOB_NAME@@|${JOB_NAME}|g" \
  -e "s|@@GIT_REF@@|${GIT_REF}|g" \
  -e "s|@@GIT_REPO@@|${GIT_REPO}|g" \
  "${SCRIPT_DIR}/all-configs-task.sh")
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

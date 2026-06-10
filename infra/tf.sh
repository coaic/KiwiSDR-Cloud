#!/usr/bin/env bash
# tf.sh - Terraform wrapper that reads per-environment YAML config.
#
# Usage:
#   ./tf.sh <env> init              # configure GCS backend and download providers
#   ./tf.sh <env> plan
#   ./tf.sh <env> apply
#   ./tf.sh <env> destroy
#
# Prerequisite: run ../../scripts/bootstrap.sh <env> before the first init.

set -euo pipefail

ENV="${1:?usage: tf.sh <env> <init|plan|apply|destroy>}"
CMD="${2:?usage: tf.sh <env> <init|plan|apply|destroy>}"
CONFIG="environments/${ENV}.yml"
LOCAL_CONFIG="environments/${ENV}.local.yml"

if [[ ! -f "${CONFIG}" ]]; then
  echo "Error: ${CONFIG} not found" >&2
  exit 1
fi

if ! command -v yq &>/dev/null; then
  echo "Error: yq is required (brew install yq)" >&2
  exit 1
fi

# Merge base config with local overrides into a single temp file.
# dev.local.yml (gitignored) overrides dev.yml — put your real project_id there.
MERGED=$(mktemp /tmp/tfvars.XXXXXX.json)
trap 'rm -f "${MERGED}"' EXIT

if [[ -f "${LOCAL_CONFIG}" ]]; then
  yq -o=json "${CONFIG}" \
    | yq -o=json ". * $(yq -o=json "${LOCAL_CONFIG}")" \
    > "${MERGED}"
else
  yq -o=json "${CONFIG}" > "${MERGED}"
fi

PROJECT_ID=$(yq '.project_id' "${MERGED}")
TFSTATE_BUCKET=$(yq '.tfstate_bucket' "${MERGED}")

if [[ "${PROJECT_ID}" == "YOUR-UNIQUE-PROJECT-ID" ]]; then
  echo "Error: copy environments/${ENV}.yml to environments/${ENV}.local.yml and set project_id" >&2
  exit 1
fi

if [[ "${CMD}" == "init" ]]; then
  echo "--- terraform init [env=${ENV}, state=gs://${TFSTATE_BUCKET}/infra/${ENV}] ---"
  terraform init \
    -backend-config="bucket=${TFSTATE_BUCKET}" \
    -backend-config="prefix=infra/${ENV}" \
    "${@:3}"
  exit 0
fi

# Strip tfstate_bucket (not a Terraform variable) before passing to plan/apply/destroy.
VARFILE=$(mktemp /tmp/tfvars.XXXXXX.json)
trap 'rm -f "${VARFILE}"' EXIT
yq 'del(.tfstate_bucket)' "${MERGED}" -o=json > "${VARFILE}"

echo "--- terraform ${CMD} [env=${ENV}] ---"
terraform "${CMD}" -var-file="${VARFILE}" "${@:3}"

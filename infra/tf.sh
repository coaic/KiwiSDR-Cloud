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

if [[ ! -f "${CONFIG}" ]]; then
  echo "Error: ${CONFIG} not found" >&2
  exit 1
fi

if ! command -v yq &>/dev/null; then
  echo "Error: yq is required (brew install yq)" >&2
  exit 1
fi

LOCAL_CONFIG="environments/${ENV}.local.yml"

TFSTATE_BUCKET=$(yq '.tfstate_bucket' "${CONFIG}")

if [[ "${CMD}" == "init" ]]; then
  echo "--- terraform init [env=${ENV}, state=gs://${TFSTATE_BUCKET}/infra/${ENV}] ---"
  terraform init \
    -backend-config="bucket=${TFSTATE_BUCKET}" \
    -backend-config="prefix=infra/${ENV}" \
    "${@:3}"
  exit 0
fi

# Convert YAML → tfvars JSON for plan/apply/destroy
# If a local override file exists (gitignored), merge it over the base config.
TMPFILE=$(mktemp /tmp/tfvars.XXXXXX.json)
trap 'rm -f "${TMPFILE}"' EXIT

if [[ -f "${LOCAL_CONFIG}" ]]; then
  yq -o=json 'del(.tfstate_bucket)' "${CONFIG}" \
    | yq -o=json ". * $(yq -o=json 'del(.tfstate_bucket)' "${LOCAL_CONFIG}")" \
    > "${TMPFILE}"
else
  yq -o=json 'del(.tfstate_bucket)' "${CONFIG}" > "${TMPFILE}"
fi

echo "--- terraform ${CMD} [env=${ENV}] ---"
terraform "${CMD}" -var-file="${TMPFILE}" "${@:3}"

#!/usr/bin/env bash
# bootstrap.sh - One-time setup: create the Terraform state bucket.
#
# Run this BEFORE "tf.sh <env> init". The tfstate bucket cannot be managed
# by the same Terraform workspace that uses it as a backend (chicken-and-egg),
# so it is created directly with gsutil.
#
# Usage:
#   ./scripts/bootstrap.sh <env>
#
# Example:
#   ./scripts/bootstrap.sh dev

set -euo pipefail

ENV="${1:?usage: bootstrap.sh <env>}"
CONFIG="infra/environments/${ENV}.yml"
LOCAL_CONFIG="infra/environments/${ENV}.local.yml"

if [[ ! -f "${CONFIG}" ]]; then
  echo "Error: ${CONFIG} not found" >&2
  exit 1
fi

if ! command -v yq &>/dev/null; then
  echo "Error: yq is required (brew install yq)" >&2
  exit 1
fi

# First run: create dev.local.yml with the minimum required values.
if [[ ! -f "${LOCAL_CONFIG}" ]]; then
  echo "--- First run: no ${LOCAL_CONFIG} found ---"
  echo ""
  read -r -p "GCP project ID (must be globally unique): " _project_id
  read -r -p "Your email (for IAM submitter access):    " _email
  cat > "${LOCAL_CONFIG}" <<EOF
# Local deployment config — gitignored, never commit.
# All values here override infra/environments/${ENV}.yml.
project_id: ${_project_id}
submitter_email: ${_email}
tfstate_bucket: ${_project_id}-fpga-tfstate
EOF
  echo ""
  echo "Created ${LOCAL_CONFIG}"
  echo ""
fi

# Merge base config with local overrides (local wins on any key present in both).
MERGED=$(mktemp)
trap 'rm -f "${MERGED}"' EXIT

yq -o=json "${CONFIG}" \
  | yq -o=json ". * $(yq -o=json "${LOCAL_CONFIG}")" \
  > "${MERGED}"

PROJECT_ID=$(yq '.project_id' "${MERGED}")
REGION=$(yq '.region' "${MERGED}")
TFSTATE_BUCKET=$(yq '.tfstate_bucket' "${MERGED}")

if [[ "${PROJECT_ID}" == "YOUR-UNIQUE-PROJECT-ID" ]]; then
  echo "Error: edit ${LOCAL_CONFIG} and set project_id" >&2
  exit 1
fi

# Enable prerequisite APIs that must exist before Terraform can use
# user_project_override (needed for Billing Budgets API)
echo "Enabling prerequisite APIs..."
gcloud services enable cloudresourcemanager.googleapis.com iam.googleapis.com \
  --project "${PROJECT_ID}"
echo "APIs enabled."
echo

echo "Bootstrap: creating Terraform state bucket gs://${TFSTATE_BUCKET}"
echo "  Project : ${PROJECT_ID}"
echo "  Region  : ${REGION}"
echo

if gsutil ls -b "gs://${TFSTATE_BUCKET}" &>/dev/null; then
  echo "Bucket already exists — skipping creation"
else
  gsutil mb -p "${PROJECT_ID}" -l "${REGION}" -b on "gs://${TFSTATE_BUCKET}"
  echo "Bucket created."
fi

gsutil versioning set on "gs://${TFSTATE_BUCKET}"
echo "Versioning enabled."

echo
echo "Next steps:"
echo "  cd infra && ./tf.sh ${ENV} init"
echo "  ./tf.sh ${ENV} plan"
echo "  ./tf.sh ${ENV} apply"

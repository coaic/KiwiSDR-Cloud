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

if [[ ! -f "${CONFIG}" ]]; then
  echo "Error: ${CONFIG} not found — fill in your project details first" >&2
  exit 1
fi

if ! command -v yq &>/dev/null; then
  echo "Error: yq is required (brew install yq)" >&2
  exit 1
fi

PROJECT_ID=$(yq '.project_id' "${CONFIG}")
REGION=$(yq '.region' "${CONFIG}")
TFSTATE_BUCKET=$(yq '.tfstate_bucket' "${CONFIG}")

if [[ "${PROJECT_ID}" == "YOUR_GCP_PROJECT_ID" ]]; then
  echo "Error: edit ${CONFIG} and set project_id before running bootstrap" >&2
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

# Create bucket if it doesn't already exist
if gsutil ls -b "gs://${TFSTATE_BUCKET}" &>/dev/null; then
  echo "Bucket already exists — skipping creation"
else
  gsutil mb -p "${PROJECT_ID}" -l "${REGION}" -b on "gs://${TFSTATE_BUCKET}"
  echo "Bucket created."
fi

# Versioning lets you recover from accidental state corruption
gsutil versioning set on "gs://${TFSTATE_BUCKET}"
echo "Versioning enabled."

echo
echo "Next steps:"
echo "  cd infra && ./tf.sh ${ENV} init"
echo "  ./tf.sh ${ENV} plan"
echo "  ./tf.sh ${ENV} apply"

#!/usr/bin/env bash
# setup-gcp.sh — one-time GCP resource creation for KiwiSDR FPGA builds.
# Run this once from the repo root before bootstrap.sh.
# Prerequisites: gcloud auth login && gcloud auth application-default login

set -euo pipefail

ENV="${1:-dev}"
CONFIG="infra/environments/${ENV}.yml"
LOCAL_CONFIG="infra/environments/${ENV}.local.yml"

if ! command -v yq &>/dev/null; then
  echo "Error: yq is required (brew install yq)" >&2
  exit 1
fi

# First run: create dev.local.yml with the minimum required values.
if [[ ! -f "${LOCAL_CONFIG}" ]]; then
  echo "--- First run: no ${LOCAL_CONFIG} found ---"
  echo ""
  read -r -p "GCP project ID (must be globally unique):          " _project_id
  read -r -p "Your email (for IAM submitter access):             " _email
  read -r -p "GCP billing account ID (gcloud billing accounts list): " _billing
  cat > "${LOCAL_CONFIG}" <<EOF
# Local deployment config — gitignored, never commit.
# All values here override infra/environments/${ENV}.yml.
project_id: ${_project_id}
submitter_email: ${_email}
tfstate_bucket: ${_project_id}-fpga-tfstate
billing_account: "${_billing}"
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
BILLING_ACCOUNT=$(yq '.billing_account' "${MERGED}")

if [[ "${PROJECT_ID}" == "YOUR-UNIQUE-PROJECT-ID" ]]; then
  echo "Error: edit ${LOCAL_CONFIG} and set project_id" >&2
  exit 1
fi

if [[ -z "${BILLING_ACCOUNT}" ]]; then
  echo "Error: set billing_account in ${LOCAL_CONFIG} (gcloud billing accounts list)" >&2
  exit 1
fi

echo "=== Setting up KiwiSDR FPGA build infrastructure ==="
echo "Project: ${PROJECT_ID}  Region: ${REGION}"

# Project
gcloud projects create "${PROJECT_ID}" --name="KiwiSDR FPGA Builds" 2>/dev/null || echo "Project already exists"
gcloud billing projects link "${PROJECT_ID}" --billing-account="${BILLING_ACCOUNT}"

# APIs
gcloud services enable \
  storage.googleapis.com \
  compute.googleapis.com \
  batch.googleapis.com \
  iam.googleapis.com \
  logging.googleapis.com \
  --project="${PROJECT_ID}"

# GCS buckets — names derived from project ID + project number (globally unique).
# Terraform uses the same derivation; bucket names must match exactly.
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
INSTALLER_BUCKET="${PROJECT_ID}-${PROJECT_NUMBER}-fpga-installer"
ARTIFACTS_BUCKET="${PROJECT_ID}-${PROJECT_NUMBER}-fpga-artifacts"
gsutil mb -p "${PROJECT_ID}" -l "${REGION}" "gs://${INSTALLER_BUCKET}"  2>/dev/null || echo "Installer bucket already exists"
gsutil mb -p "${PROJECT_ID}" -l "${REGION}" "gs://${ARTIFACTS_BUCKET}" 2>/dev/null || echo "Artifacts bucket already exists"

# 90-day lifecycle on artifacts (bitstreams are small, cheap to keep)
gsutil lifecycle set /dev/stdin "gs://${ARTIFACTS_BUCKET}" <<'EOF'
{"rule":[{"action":{"type":"Delete"},"condition":{"age":90}}]}
EOF

# Service account (used by Cloud Batch VMs — no key file created)
gcloud iam service-accounts create fpga-builder \
  --project="${PROJECT_ID}" \
  --display-name="FPGA Builder" 2>/dev/null || echo "Service account already exists"

SA_EMAIL="fpga-builder@${PROJECT_ID}.iam.gserviceaccount.com"

# Scope objectAdmin to the artifacts bucket only (not project-wide).
# Terraform manages this binding with the same scope — run tf apply after this script.
gsutil iam ch "serviceAccount:${SA_EMAIL}:roles/storage.objectAdmin" \
  "gs://${ARTIFACTS_BUCKET}"
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" --role="roles/batch.agentReporter"
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" --role="roles/logging.logWriter"

echo
echo "=== Done. Next steps ==="
echo "1. Obtain and upload the Vivado 2024.2 installer:"
echo "   The installer must be downloaded directly from AMD/Xilinx (free account required)."
echo "   Download: https://www.xilinx.com/support/download/index.html/content/xilinx/en/downloadNav/vivado-design-suite/archive.html"
echo "   Select: Vivado 2024.2 -> Vivado HLx 2024.2: All OS installer Single-File Download"
echo "   File: FPGAs_AdaptiveSoCs_Unified_2024.2_*.tar (~125 GB)"
echo "   Then upload:"
echo "   gsutil cp ~/Downloads/FPGAs_AdaptiveSoCs_Unified_2024.2_*.tar gs://${INSTALLER_BUCKET}/"
echo "2. Create the Terraform state bucket:"
echo "   ./scripts/bootstrap.sh ${ENV}"
echo "3. Apply infrastructure:"
echo "   cd infra && ./tf.sh ${ENV} init && ./tf.sh ${ENV} apply"
echo "4. Bake Vivado image:"
echo "   cd packer && packer build -var project_id=${PROJECT_ID} -var vivado_installer_gcs=gs://${INSTALLER_BUCKET}/FPGAs_AdaptiveSoCs_Unified_2024.2_*.tar vivado-image.pkr.hcl"
echo "5. Submit a build:"
echo "   export GCP_PROJECT=${PROJECT_ID}"
echo "   ./scripts/submit-build.sh https://github.com/coaic/KiwiSDR.git master rx44"

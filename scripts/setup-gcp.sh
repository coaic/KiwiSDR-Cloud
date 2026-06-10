#!/usr/bin/env bash
# setup-gcp.sh — one-time GCP resource creation for KiwiSDR FPGA builds.
# Run this once from your local machine. No state files, no Terraform.
# Prerequisites: gcloud auth login && gcloud auth application-default login

set -euo pipefail

PROJECT_ID="${GCP_PROJECT:-kiwisdr-fpga-builds}"
REGION="${GCP_REGION:-australia-southeast1}"
BILLING_ACCOUNT="${BILLING_ACCOUNT:?set BILLING_ACCOUNT env var (gcloud billing accounts list)}"

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

# GCS buckets
# Installer bucket uses a short name (not prefixed with project ID) — must match
# infra/environments/dev.yml installer_bucket_name and Terraform state.
gsutil mb -p "${PROJECT_ID}" -l "${REGION}" "gs://kiwisdr-fpga-installer"          2>/dev/null || echo "Installer bucket already exists"
gsutil mb -p "${PROJECT_ID}" -l "${REGION}" "gs://${PROJECT_ID}-fpga-artifacts"    2>/dev/null || echo "Artifacts bucket already exists"

# 90-day lifecycle on artifacts (bitstreams are small, cheap to keep)
gsutil lifecycle set /dev/stdin "gs://${PROJECT_ID}-fpga-artifacts" <<'EOF'
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
  "gs://${PROJECT_ID}-fpga-artifacts"
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
echo "   gsutil cp ~/Downloads/FPGAs_AdaptiveSoCs_Unified_2024.2_*.tar gs://kiwisdr-fpga-installer/"
echo "2. Bake Vivado image:"
echo "   cd packer && packer build -var project_id=${PROJECT_ID} -var vivado_installer_gcs=gs://kiwisdr-fpga-installer/FPGAs_AdaptiveSoCs_Unified_2024.2_*.tar vivado-image.pkr.hcl"
echo "3. Submit a build:"
echo "   export GCP_PROJECT=${PROJECT_ID}"
echo "   ./scripts/submit-build.sh https://github.com/coaic/KiwiSDR.git master rx44"

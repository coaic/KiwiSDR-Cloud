# KiwiSDR-Cloud — GCP Build Infrastructure

Cloud build infrastructure for [KiwiSDR](https://github.com/jks-prv/KiwiSDR) gateware.
Synthesises the Artix-7 A35 FPGA bitstreams on ephemeral Google Cloud Batch SPOT VMs
using Vivado 2024.2, without requiring a local x86-64 Vivado installation.

This repo is intentionally separate from the KiwiSDR source tree. It references the
KiwiSDR repo as an external git URL — no modifications to the upstream project are
required to use it.

## Project Structure

```
KiwiSDR-Cloud/
├── packer/
│   ├── vivado-image.pkr.hcl      # Bakes GCP image: Ubuntu 20.04 + Vivado 2024.2
│   └── install_config.txt        # Vivado silent install config (ML Standard, Artix-7)
├── infra/
│   ├── main.tf                   # Root module — wires modules to variables
│   ├── variables.tf              # Variable declarations
│   ├── outputs.tf
│   ├── tf.sh                     # YAML→Terraform wrapper (needs yq)
│   ├── environments/
│   │   └── dev.yml               # All environment-specific config lives here
│   └── modules/
│       ├── apis/                 # GCP API enablement
│       ├── storage/              # GCS buckets (artifacts + installer)
│       ├── iam/                  # Service account + IAM bindings
│       ├── networking/           # Default subnet Private Google Access + Cloud NAT
│       └── budget/               # Optional billing budget alerts
├── scripts/
│   ├── setup-gcp.sh              # One-time GCP resource creation (no Terraform needed)
│   ├── bootstrap.sh              # Create Terraform state bucket before first tf init
│   ├── submit-build.sh           # Submit a single-config Cloud Batch build
│   └── submit-all-configs.sh     # Submit all 4 configs (2 parallel, quota-safe)
└── docs/
    ├── vivado-batch-ip-handling.md  # Why/how make_proj.tcl is patched at runtime
    └── vivado-remote-desktop-plan.md  # Plan for GCP-hosted Vivado GUI session
```

## Design Principles

- **Ephemeral compute**: Cloud Batch SPOT VMs spin up per job, terminate on completion.
- **Persistent artifacts**: GCS bucket stores bitstreams and logs with 90-day lifecycle.
- **No secrets in repo**: No service account keys. VMs authenticate via GCE metadata.
  Local auth via `gcloud auth application-default login`.
- **No KiwiSDR fork modifications required**: The IP import patch is applied transiently
  on the VM by `submit-build.sh`. See `docs/vivado-batch-ip-handling.md`.

## GCP Resources

| Resource | Name | Notes |
|---|---|---|
| Project | `kiwisdr-fpga-builds` | |
| Artifacts bucket | `kiwisdr-fpga-builds-fpga-artifacts` | 90-day lifecycle |
| Installer bucket | `kiwisdr-fpga-installer` | Permanent |
| Terraform state | `kiwisdr-fpga-builds-fpga-tfstate` | Versioned |
| Image family | `vivado-2024-2` | Ubuntu 20.04 Pro + Vivado 2024.2 ML Standard |
| Service account | `fpga-builder@kiwisdr-fpga-builds.iam.gserviceaccount.com` | No key file |
| Cloud NAT | `fpga-build-nat` | Outbound internet for git clone |

## Vivado Target

| | |
|---|---|
| Edition | ML Standard (free, supports Artix-7) |
| Device | Artix-7 A35 (`xc7a35tftg256-1`) |
| Version | 2024.2 |
| Configurations | rx44, rx82, rx33, rx14 |

## Quick Reference

```bash
# First-time setup (if starting from scratch)
export BILLING_ACCOUNT=$(gcloud billing accounts list --format="value(name)" | head -1)
export GCP_PROJECT=kiwisdr-fpga-builds
./scripts/setup-gcp.sh

# Terraform (manages networking, IAM, buckets)
cd infra && ./tf.sh dev init && ./tf.sh dev apply

# Bake Vivado image (~2.5 hours, once)
cd packer && packer init . && packer build \
  -var project_id=kiwisdr-fpga-builds \
  -var "vivado_installer_gcs=gs://kiwisdr-fpga-installer/FPGAs_AdaptiveSoCs_Unified_2024.2_*.tar" \
  vivado-image.pkr.hcl

# Submit a single config build
export GCP_PROJECT=kiwisdr-fpga-builds
./scripts/submit-build.sh https://github.com/coaic/KiwiSDR.git master rx44

# Submit all 4 configs (2 at a time)
./scripts/submit-all-configs.sh https://github.com/coaic/KiwiSDR.git master

# Fetch bitstreams when done
gsutil cp 'gs://kiwisdr-fpga-builds-fpga-artifacts/<job-name>/*.bit' ./
```

## Docs

- [Troubleshooting](docs/troubleshooting.md) — IAM requirements, common failures, diagnosing with Claude
- [Vivado Batch IP Handling](docs/vivado-batch-ip-handling.md) — why make_proj.tcl is
  patched at runtime and how the IP cache works
- [Remote Desktop Plan](docs/vivado-remote-desktop-plan.md) — GCP-hosted Vivado GUI
  for IP configuration and RTL editing (PoC planned, not yet implemented)

## Related

- [KiwiSDR upstream](https://github.com/jks-prv/KiwiSDR) — original project
- [coaic/KiwiSDR](https://github.com/coaic/KiwiSDR) — fork used as build source
- [redpitaya-cloud](../redpitaya-cloud/) — sister project, same cloud pattern for Red Pitaya Gen 2

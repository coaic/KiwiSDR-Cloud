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
│   ├── submit-all-configs.sh     # Submit all 4 configs (2 parallel, quota-safe)
│   └── patch_make_proj.py        # Injects kiwi::make_ipcores call into make_proj.tcl
└── docs/
    ├── workflow.md                  # Edit → build → timing loop; AI agent usage
    ├── troubleshooting.md           # IAM requirements, common failures, diagnosing with Claude
    ├── vivado-batch-ip-handling.md  # Why/how make_proj.tcl is patched at runtime
    ├── vivado-remote-desktop-plan.md  # Plan for GCP-hosted Vivado GUI session
    └── new-project-prompt.md        # Bootstrap prompt for starting a new cloud build project
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
| Image family | `vivado-2024-2` | Ubuntu 20.04 Pro + Vivado 2024.2 ML Standard. **Baked on demand — not kept persistently** (see Image Lifecycle below) |
| Service account | `fpga-builder@kiwisdr-fpga-builds.iam.gserviceaccount.com` | No key file |
| Cloud NAT | `fpga-build-nat` | Outbound internet for git clone |

## Image Lifecycle

The `vivado-2024-2` custom image (~300 GB) is **not kept in GCP between work
cycles** — at ~$0.05/GB/mo it costs ~$15/mo idle, and this repo is used
infrequently. Instead it is baked on demand:

- **Before a cycle of work**: bake the image once with the `packer build`
  command in the Quick Reference above. It joins the `vivado-2024-2` family,
  and the build scripts (`submit-build.sh`, `submit-all-configs.sh`) that
  reference the family then work unchanged.
- **During a cycle**: keep the image. Do **not** delete it while a series of
  changes is still in progress or a revisit is likely soon.
- **After a cycle**: once the work is complete and the repo won't be revisited
  for weeks or months, delete the image to stop the storage cost:
  `gcloud compute images delete <image-name> --project=kiwisdr-fpga-builds`.
- **Rule for Claude**: never delete the image unprompted. Ask the user whether
  they've finished the cycle before deleting.

The image is not managed by Terraform, so deleting it causes no `tf` drift.

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

- [Workflow](docs/workflow.md) — edit gateware → submit build → check timing loop
- [Troubleshooting](docs/troubleshooting.md) — IAM requirements, common failures, diagnosing with Claude
- [Vivado Batch IP Handling](docs/vivado-batch-ip-handling.md) — why make_proj.tcl is
  patched at runtime and how IPs are created
- [Remote Desktop Plan](docs/vivado-remote-desktop-plan.md) — GCP-hosted Vivado GUI
  for IP configuration and RTL editing (PoC planned, not yet implemented)

## Related

- [KiwiSDR upstream](https://github.com/jks-prv/KiwiSDR) — original project
- [coaic/KiwiSDR](https://github.com/coaic/KiwiSDR) — fork used as build source
- [redpitaya-cloud](../redpitaya-cloud/) — sister project, same cloud pattern for Red Pitaya Gen 2

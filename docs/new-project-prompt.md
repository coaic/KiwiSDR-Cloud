# New Project Setup Prompt

This document is a prompt you can paste into an AI assistant (such as Claude) to
get help setting up cloud FPGA build infrastructure for any Xilinx/AMD project on
Apple Silicon.

---

## The Problem

Xilinx/AMD Vivado has no Apple Silicon (M1/M2/M3/M4) support and never will.
With Apple deprecating Intel Macs, anyone doing Xilinx FPGA development on a Mac
faces a wall: synthesis and place-and-route simply won't run locally.

## The Solution

Run Vivado on ephemeral x86-64 SPOT VMs in Google Cloud Batch. A Packer-baked
GCP image contains the full Vivado installation. Jobs spin up, clone the repo,
synthesise, upload the bitstream to GCS, and terminate — you pay only for the
~10–60 minutes of compute actually used.

Two reference implementations exist:

- **[redpitaya-cloud](https://github.com/coaic/redpitaya-cloud)** — Vivado 2020.1,
  Zynq-7020, single build config. Fully validated.
- **[kiwisdr-cloud](https://github.com/coaic/kiwisdr-cloud)** — Vivado 2024.2,
  Artix-7 A35, 4 build configs with IP cache pre-baked into the image.

Both repos are MIT licensed. Fork either one as a starting point.

---

## How to Use This Prompt

1. Fill in the **About Your Project** section below with your project's specifics.
2. Paste this entire document into Claude (or another AI assistant).
3. The AI will help you create a `<your-project>-cloud` repository tailored to
   your project, modelled on the reference repos above.

---

## About Your Project

Fill in these details before pasting:

| Field | Your answer |
|---|---|
| Project name | (e.g. `myproject`) |
| Repo name convention | `<project-name>-cloud` |
| Git repo URL | (e.g. `https://github.com/org/repo.git`) |
| Vivado version required | (check your project's Makefile or TCL scripts) |
| Vivado edition needed | WebPACK (free) / ML Standard / ML Enterprise |
| Target FPGA device | (e.g. `xc7a35tftg256-1`, `xc7z020clg484-1`) |
| Build command | (e.g. `make bitstream`, or Tcl: `vivado -mode batch -source build.tcl`) |
| Output file(s) | (e.g. `out/*.bit`, `build/top.bit`) |
| Number of build configurations | (1 for most projects) |
| GCP project ID (desired) | (e.g. `myproject-fpga-builds`) |
| GCP region (nearest) | (e.g. `us-central1`, `europe-west1`, `australia-southeast1`) |

---

## Installer Note

> **The Vivado installer must be downloaded directly from AMD/Xilinx.**
> It cannot be redistributed and is not available from any third-party source.
> A free AMD account is required.
>
> Download: https://www.xilinx.com/support/download/index.html/content/xilinx/en/downloadNav/vivado-design-suite/archive.html

The installer (~52 GB for 2020.1, ~125 GB for 2024.2) is uploaded once to a
private GCS bucket that you own. It is never shared or re-distributed.

---

## AI Prompt

You are helping set up Google Cloud FPGA build infrastructure for an Apple Silicon
Mac developer. Xilinx/AMD Vivado has no ARM/Apple Silicon support, so synthesis
runs on ephemeral x86-64 SPOT VMs in Google Cloud Batch.

Two reference repositories implement this pattern (both MIT licensed):

- https://github.com/coaic/redpitaya-cloud (Vivado 2020.1, Zynq-7020, 1 config)
- https://github.com/coaic/kiwisdr-cloud (Vivado 2024.2, Artix-7 A35, 4 configs)

The developer's project details are in the "About Your Project" table above.

Please help create a complete `<project-name>-cloud` repository containing:

1. `packer/vivado-image.pkr.hcl` — bakes a GCP image with Vivado installed.
   Use the streaming approach (`gsutil cp gs://... - | tar xz -C /tmp/vivado`)
   from redpitaya-cloud for .tar.gz installers, or the download-then-extract
   approach from kiwisdr-cloud for .tar installers where resumption matters.

2. `infra/` — Terraform modules: `apis`, `storage`, `iam`, `networking`, `budget`.
   Follow the module structure from the reference repos exactly.

3. `scripts/submit-build.sh` — submits a Cloud Batch job that clones the repo,
   runs the build command, and uploads output `.bit` files and `build.log` to GCS.
   Use the metadata-token curl approach (no gsutil dependency on the VM).

4. `scripts/bootstrap.sh` — creates the Terraform state bucket before first init.

5. `docs/getting-started.md` — step-by-step setup guide. Must include a prominent
   note that the Vivado installer must be obtained from AMD/Xilinx directly, with
   the download URL, and must never be redistributed.

6. `CLAUDE.md` — project context file following the pattern from the reference repos.

Key requirements:
- Image family named `vivado-<version>` (e.g. `vivado-2020-1`, `vivado-2024-2`).
  This naming is intentional: the image is version-specific, not project-specific.
  Multiple projects that share a Vivado version can share the same baked image.
- No service account keys in the repo. VMs authenticate via GCE instance metadata.
- VMs have no public IP. Use Private Google Access + Cloud NAT for outbound traffic.
- Artifacts bucket: `<project-id>-fpga-artifacts` with configurable lifecycle.
- Installer bucket: `<project-id>-fpga-installer` — permanent, no lifecycle rule.
- Terraform state bucket: `<project-id>-fpga-tfstate` — created by bootstrap.sh.
- Use SPOT (preemptible) VMs for batch jobs to minimise cost.
- All GCS uploads from the VM use curl + GCE metadata token, not gsutil, to avoid
  snap/PATH issues on Ubuntu.

Reference the existing repos for exact patterns. Adapt for the Vivado version,
device, build command, and output file pattern provided above.

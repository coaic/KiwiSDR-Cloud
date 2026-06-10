# Vivado Remote Desktop — Plan

A persistent GCP VM running XFCE + XRDP would allow you to run the Vivado GUI
over an IAP RDP tunnel — no local x86-64 machine needed for IP configuration,
constraint editing, or timing analysis.

This is not yet implemented for KiwiSDR-Cloud.

## Reference Implementation

The sister project **redpitaya-cloud** has this fully working:
- VM: `vivado-desktop`, n2-standard-4, `vivado-2020-1` image
- Access: IAP tunnel → Microsoft Remote Desktop → `localhost:3389`
- Scripts: `start-desktop.sh` / `stop-desktop.sh`

See [redpitaya-cloud](https://github.com/coaic/redpitaya-cloud) for the working
implementation to adapt from.

## When to Implement

The main use case for KiwiSDR is running the Vivado IP Integrator to reconfigure
IP core parameters, or checking timing reports interactively. If you find yourself
needing to do this regularly, follow the redpitaya-cloud pattern:

1. Add a `vivado-desktop` VM resource to Terraform (or create it manually)
2. Reuse the existing `vivado-2024-2` image — it has Vivado installed
3. Install XFCE + XRDP on the image (add to `packer/vivado-image.pkr.hcl`)
4. Add `start-desktop.sh` / `stop-desktop.sh` scripts

The VM should be stopped when not in use to avoid idle compute charges.

# Vivado Batch Mode IP Handling

## Background

KiwiSDR uses 22 Xilinx IP cores (BRAMs, DSPs, DDS). In the normal desktop workflow
the Vivado GUI handles IP compilation via two manual steps:

**Step 3** (README.Vivado.2024.2.txt): Copy `verilog.Vivado.2022.2.ip/` to `import_ip/`

**Step 8**: Add Sources → Add Directories → select `import_ip/` → **Copy sources checked**

This copies the `.xci` IP definition files into the Vivado project, which Vivado then
compiles on first synthesis.

## The Batch Mode Problem

`make_proj.tcl` supports a `--regen_ip` flag that is meant to replicate step 8 in batch
mode. It calls `kiwi::make_ipcores` which reads IP properties from `ipcore_properties/*.txt`
and creates fresh IP XCI files. However, as noted in `verilog/Makefile`:

> 7/2025 NB: With Vivado 2024.2 this doesn't seem to be working currently.

Without `--regen_ip`, `make_proj.tcl` only adds Verilog source files to the project.
IP cores are never created so synthesis fails with:
```
ERROR: [Synth 8-439] module 'ipcore_dds_sin_cos_13b_15b_48b' not found
```

## What Was Tried and Why It Failed

**`import_ip` + `upgrade_ip` + `synth_ip`**: Imports the existing 2022.2 `.xci` files
and upgrades them to 2024.2. This gets through synthesis but fails at implementation:
```
ERROR: [Opt 31-67] Problem: A LUT2 cell in the design is missing a connection on input pin I1
```
The Block Memory Generator IP from 2022.2 produces broken LUT connections when
upgraded to 2024.2's `opt_design` phase — a known Vivado version compatibility issue.

## The Fix

`submit-build.sh` patches `make_proj.tcl` on the VM before running Vivado. The patch
injects a call to `kiwi::make_ipcores` immediately after the Verilog `add_files` call:

```tcl
# Create IP cores from scratch for Vivado 2024.2 using ipcore_properties/ txt files.
# This bypasses the 2022.2 XCIs entirely, avoiding upgrade compatibility issues.
if {[string equal $proj_create "yes"]} {
    kiwi::make_ipcores
}
```

`kiwi::make_ipcores` (defined in `kiwi.tcl`) reads each IP's configuration from
`KiwiSDR/import_srcs/ipcore_properties/ipcore_*.txt` and calls `create_ip` with the
correct 2024.2 parameters. Each IP is created fresh for the current Vivado version —
no upgrade step needed, no compatibility issues.

## Why the Patch Lives Here, Not in the KiwiSDR Fork

The patch is applied transiently on the VM and never persisted to the repo for two reasons:

1. **No KiwiSDR fork dependency** — the build VM clones the upstream KiwiSDR repo
   directly. Keeping the patch here means it works regardless of what's been pushed
   to any fork.

2. **Clean separation** — `make_proj.tcl` is part of the KiwiSDR project and should not
   carry cloud-specific modifications.

## Build Time

IPs are compiled fresh on each build by `kiwi::make_ipcores`. With an n2-standard-8 VM
and the Artix-7 A35 device, a full synthesis + implementation run takes approximately
8 minutes end-to-end.

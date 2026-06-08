# Vivado Batch Mode IP Handling

## Background

KiwiSDR uses 22 Xilinx IP cores (BRAMs, DSPs, DDS). In the normal desktop workflow
the Vivado GUI handles IP compilation via two manual steps:

**Step 3** (README.Vivado.2024.2.txt): Copy `verilog.Vivado.2022.2.ip/` to `import_ip/`

**Step 8**: Add Sources → Add Directories → select `import_ip/` → **Copy sources checked**

This copies the `.xci` IP definition files into the Vivado project, which Vivado then
compiles on first synthesis (~30 min).

## The Batch Mode Problem

`make_proj.tcl` supports a `--regen_ip` flag that is meant to replicate step 8 in batch
mode. It calls `kiwi::make_ipcores` which reads IP properties from `ipcore_properties/*.txt`
and regenerates the IP XCI files.

However, as noted in `verilog/Makefile`:
> 7/2025 NB: With Vivado 2024.2 this doesn't seem to be working currently.

Without `--regen_ip`, `make_proj.tcl` only adds Verilog source files to the project. The
IP XCI files in `import_ip/` are never imported, so synthesis fails with:
```
ERROR: [Synth 8-439] module 'ipcore_dds_sin_cos_13b_15b_48b' not found
```

## The Fix

`submit-build.sh` patches `make_proj.tcl` on the VM before running Vivado. The patch
injects a TCL block immediately after the Verilog `add_files` call:

```tcl
# Import IP XCI files from import_ip/ (cloud batch equivalent of GUI step 8)
if {[string equal $proj_create "yes"]} {
    foreach xci_file [glob -nocomplain KiwiSDR/import_ip/*.xci] {
        import_ip $xci_file
    }
    upgrade_ip -quiet [get_ips *]
    generate_target all [get_ips *]
}
```

`import_ip` copies each XCI file into the project and registers it as a source.
`upgrade_ip` updates any IP versions that have changed between Vivado 2022.2 (when the
`.xci` files were created) and 2024.2. `generate_target all` pre-compiles the IP so
synthesis can use the output products directly.

## Why the Patch Lives Here, Not in the KiwiSDR Fork

The patch is embedded inline in `submit-build.sh` for two reasons:

1. **No KiwiSDR fork dependency** — the build VM clones the upstream KiwiSDR repo
   directly. Keeping the patch here means it works regardless of what's been pushed
   to any fork.

2. **Clean separation** — `make_proj.tcl` is part of the KiwiSDR project and should not
   carry cloud-specific modifications. The patch is applied transiently on the VM and
   never persisted to the repo.

## IP Cache

To avoid recompiling IPs (~30 min) on every build, the Packer image runs a warm-up
`rx4_wf4` build during image baking and archives the resulting compiled IP objects to
`/opt/kiwisdr-ip-cache/`. Each batch job restores this cache before running Vivado.

If the cache is missing or stale (e.g. after an IP version change), the build still
succeeds — it just takes ~30 min longer on that run.

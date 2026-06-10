#!/usr/bin/env python3
# patch_make_proj.py — patch make_proj.tcl for cloud batch builds.
#
# Injects a call to kiwi::make_ipcores after the source-file add step.
# This creates all 22 IP cores from scratch using ipcore_properties/*.txt,
# bypassing the 2022.2 XCI files entirely (which cause broken LUT connections
# when upgraded to Vivado 2024.2's opt_design).
#
# See docs/vivado-batch-ip-handling.md for full explanation.
#
# Usage: python3 patch_make_proj.py <path/to/make_proj.tcl>

import sys

path = sys.argv[1]
with open(path) as f:
    content = f.read()

MARKER = (
    'if {[string equal $proj_create "yes"]} {\n'
    '    add_files -norecurse -fileset [get_filesets sources_1] $files\n'
    '}'
)

INJECT = """
# Create IP cores from scratch for Vivado 2024.2 using ipcore_properties/ txt files.
# This bypasses the 2022.2 XCIs entirely, avoiding upgrade compatibility issues.
# kiwi::make_ipcores is defined in kiwi.tcl (sourced above).
if {[string equal $proj_create "yes"]} {
    kiwi::make_ipcores
}"""

if MARKER not in content:
    print(f"ERROR: anchor not found in {path} — make_proj.tcl may have changed", file=sys.stderr)
    sys.exit(1)

patched = content.replace(MARKER, MARKER + INJECT, 1)

with open(path, 'w') as f:
    f.write(patched)

print(f"Patched {path}: IP import block injected")

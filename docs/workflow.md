# Developer Workflow

The typical loop: edit gateware → submit cloud build → check timing → repeat.

---

## 1. Edit Gateware

Edit RTL files in your local KiwiSDR checkout (`~/Projects/Github/coaic/KiwiSDR`
or wherever you cloned `https://github.com/coaic/KiwiSDR.git`).

The FPGA source lives under `verilog/`. Key files:

- `verilog/*.v` — RTL source
- `verilog/kiwi.tcl` — IP core definitions (`kiwi::make_ipcores`)
- `verilog/import_srcs/ipcore_properties/` — per-IP parameter files

After editing, commit and push to your fork:

```bash
cd ~/Projects/Github/coaic/KiwiSDR
git add -p
git commit -m "describe change"
git push origin master   # or your branch
```

---

## 2. Submit a Cloud Build

```bash
export GCP_PROJECT=kiwisdr-fpga-builds

# Single config (fast feedback — rx44 is the common test config)
./scripts/submit-build.sh https://github.com/coaic/KiwiSDR.git master rx44

# All 4 configs (rx44, rx82, rx33, rx14) — 2 parallel tasks
./scripts/submit-all-configs.sh https://github.com/coaic/KiwiSDR.git master
```

The job prints a job name and GCS artifact path. Build takes ~8 minutes on an
n2-standard-8 SPOT VM.

Poll until done:

```bash
JOB=kiwisdr-20260101-120000   # from submit output
gcloud batch jobs describe ${JOB} \
  --location=australia-southeast1 --project=kiwisdr-fpga-builds \
  --format='value(status.state)'
```

---

## 3. Retrieve Artifacts

```bash
BUCKET=kiwisdr-fpga-builds-fpga-artifacts

# List outputs
gsutil ls "gs://${BUCKET}/${JOB}/"

# Download bitstream
gsutil cp "gs://${BUCKET}/${JOB}/*.bit" ./

# View build log (includes timing summary)
gsutil cat "gs://${BUCKET}/${JOB}/build.log"
```

---

## 4. Check Timing

**Quick check** — scan the build log for Worst Negative Slack:

```bash
gsutil cat "gs://${BUCKET}/${JOB}/build.log" | grep -E "WNS|Timing"
```

A positive WNS means timing is met. Negative means timing violation — the
bitstream may be unreliable.

**Interactive timing analysis** — open Vivado GUI on the remote desktop (see
`docs/vivado-remote-desktop-plan.md` for when this is implemented). Until then,
download the build log and search for `Timing Summary` or `Critical Warning`.

---

## 5. Iterate

If timing fails or the build errors:

1. Check `build.log` for the first `ERROR:` line
2. Fix in RTL, push to fork
3. Re-submit from step 2

See `docs/troubleshooting.md` for common failure patterns.

---

## Using an AI Coding Agent

Claude Code (or any AI coding agent) fits naturally into this workflow. The
`CLAUDE.md` in this repo loads automatically when you run `claude` from the
project root, so the agent already knows the GCP project, bucket names, image
families, build commands, the `patch_make_proj.py` mechanism, and infrastructure
layout — you don't need to explain any of that.

```bash
# From the repo root
claude
```

### Sonnet — iterative work

Use a fast, cheap model (Sonnet) for the tight edit→build→debug loop:

- **Diagnose a build failure** — paste the error from `build.log` and ask what
  caused it. Claude can read the log directly from GCS:
  ```
  fetch gs://kiwisdr-fpga-builds-fpga-artifacts/<job>/build.log and tell me
  why the build failed
  ```
- **Interpret timing** — paste the Timing Summary section and ask whether timing
  is acceptable, what the critical path is, and what RTL or constraint change
  would help.
- **Edit RTL** — describe what you want to change; Claude can read the source
  files in the KiwiSDR checkout, make the edit, and summarise what changed.
- **Submit and monitor** — ask Claude to submit a build and poll until done;
  it can run the `submit-build.sh` and `gcloud batch` commands for you.
- **IP core changes** — if you need to reconfigure an IP core, Claude can edit
  `verilog/import_srcs/ipcore_properties/ipcore_*.txt` and explain how the
  change flows through `kiwi::make_ipcores` to the synthesised netlist.
- **Infrastructure changes** — ask Claude to plan and apply Terraform changes;
  it will run `tf.sh dev plan` first and show you the diff before applying.

### Opus — final review

Before a significant build milestone (first timing closure, releasing a
bitstream, changing IP configuration), switch to Opus for a thorough review:

```
/code-review ultra
```

This spawns a multi-agent cloud review of all changed files. Useful for:

- Catching subtle RTL issues (unintended latches, clock-domain crossings,
  reset strategy) before committing to a long build run
- Verifying IP core parameter changes are correct and consistent across all
  4 configurations (rx44/rx82/rx33/rx14)
- Checking that `patch_make_proj.py` changes still correctly target the
  right anchor in `make_proj.tcl`
- Cross-checking that infrastructure changes (IAM, Terraform) are safe

Opus reviews cost more and take longer — reserve them for changes where a
missed bug would mean another full build cycle or a broken bitstream.

### Tips

- Claude has no local Vivado installation and cannot run synthesis — it works
  from source files and build logs, not from running Vivado itself.
- For timing analysis, download the `.rpt` files from GCS alongside the `.bit`
  and point Claude at them; they contain far more detail than the build log
  summary.
- If a build fails with a cryptic Vivado message, paste the full surrounding
  context (not just the error line) — Vivado errors are often consequences of
  an earlier root cause several lines up.
- When working across both the KiwiSDR source repo and this cloud repo in the
  same session, use `/add-dir` to add the source repo so Claude can read both
  without switching sessions.

---

## Retrieving a Previous Build

```bash
# List all jobs
gcloud batch jobs list --location=australia-southeast1 --project=kiwisdr-fpga-builds

# List artifacts for any job
gsutil ls "gs://kiwisdr-fpga-builds-fpga-artifacts/"
```

Artifacts are kept for 90 days (configured in `infra/environments/dev.yml`).

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

## Retrieving a Previous Build

```bash
# List all jobs
gcloud batch jobs list --location=australia-southeast1 --project=kiwisdr-fpga-builds

# List artifacts for any job
gsutil ls "gs://kiwisdr-fpga-builds-fpga-artifacts/"
```

Artifacts are kept for 90 days (configured in `infra/environments/dev.yml`).

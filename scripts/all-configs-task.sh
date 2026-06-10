#!/bin/bash
# all-configs-task.sh — runs on the Cloud Batch VM (one task per rx config).
# BATCH_TASK_INDEX (0-3) selects the config; the Batch agent sets it at runtime.
# @@MARKER@@ values are substituted by submit-all-configs.sh at submission time.
# Do not run directly.
set -e
exec > >(tee /var/log/build.log) 2>&1

export HOME=/root

CONFIGS=(rx44    rx82     rx33     rx14)
FLAGS=(--rx4_wf4 --rx8_wf2 --rx3_wf3 --rx14_wf0)

RX_CFG="${CONFIGS[$BATCH_TASK_INDEX]}"
TCL_FLAG="${FLAGS[$BATCH_TASK_INDEX]}"

gcs_token() {
  curl -sf \
    -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}

gcs_upload() {
  local src="$1" dst="$2"
  local object
  object=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "${dst}")
  curl -sf -X POST \
    -H "Authorization: Bearer $(gcs_token)" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@${src}" \
    "https://storage.googleapis.com/upload/storage/v1/b/@@BUCKET@@/o?uploadType=media&name=${object}" \
    > /dev/null \
    && echo "Uploaded ${src} -> gs://@@BUCKET@@/${dst}" \
    || echo "WARNING: upload failed for ${src}"
}

gcs_download() {
  local src="$1" dst="$2"
  local object
  object=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "${src}")
  curl -sf \
    -H "Authorization: Bearer $(gcs_token)" \
    "https://storage.googleapis.com/storage/v1/b/@@BUCKET@@/o/${object}?alt=media" \
    -o "${dst}" && echo "Downloaded gs://@@BUCKET@@/${src} -> ${dst}"
}

trap 'gcs_upload /var/log/build.log "@@JOB_NAME@@/${RX_CFG}/build.log"' EXIT

echo "=== KiwiSDR build: repo=@@GIT_REPO@@ ref=@@GIT_REF@@ cfg=${RX_CFG} ==="

gcs_download "tools/patch_make_proj.py" /tmp/patch_make_proj.py

cd /tmp
rm -rf project
git clone --depth=1 --branch "@@GIT_REF@@" "@@GIT_REPO@@" project

rm -rf /build && mkdir -p /build/KiwiSDR/import_srcs /build/KiwiSDR/import_ip /build/generated
rsync -a /tmp/project/verilog/                   /build/KiwiSDR/import_srcs/
rsync -a /tmp/project/verilog.Vivado.2022.2.ip/  /build/KiwiSDR/import_ip/
cp /tmp/project/verilog/kiwi.tcl /tmp/project/verilog/make_proj.tcl /build/

# shellcheck disable=SC2016  # \${project_name} is literal sed pattern, not a shell variable
sed -i 's/create_project \${project_name} \.\/\${project_name}/create_project -force \${project_name} .\/\${project_name}/' /build/make_proj.tcl
python3 /tmp/patch_make_proj.py /build/make_proj.tcl

# shellcheck source=/dev/null
source /tools/Xilinx/Vivado/2024.2/settings64.sh

cd /build
time vivado -mode batch -source make_proj.tcl \
  -tclargs --result_dir /build "${TCL_FLAG}" || BUILD_FAILED=1

for f in /build/KiwiSDR.*.bit /build/KiwiSDR.*.rpt; do
  [ -f "$f" ] && gcs_upload "$f" "@@JOB_NAME@@/${RX_CFG}/$(basename "$f")"
done

[ -z "${BUILD_FAILED:-}" ]

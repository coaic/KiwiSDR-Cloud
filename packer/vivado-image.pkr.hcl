# vivado-image.pkr.hcl
# Bakes a GCP custom image with Vivado 2024.2 installed for KiwiSDR gateware builds.
# Build:  packer init . && packer build -var project_id=<your-project> -var vivado_installer_gcs=gs://... .

packer {
  required_plugins {
    googlecompute = {
      source  = "github.com/hashicorp/googlecompute"
      version = "~> 1.1"
    }
  }
}

variable "project_id" {
  type = string
}

variable "zone" {
  type    = string
  default = "australia-southeast1-a"
}

variable "vivado_installer_gcs" {
  type        = string
  description = "gs:// URL of FPGAs_AdaptiveSoCs_Unified_2024.2_*.tar in your installer bucket"
}

source "googlecompute" "vivado" {
  project_id              = var.project_id
  zone                    = var.zone
  source_image_family      = "ubuntu-pro-2004-lts"
  source_image_project_id  = ["ubuntu-os-pro-cloud"]
  machine_type            = "n2-standard-8"  # only used during image bake
  disk_size               = 400              # tar ~125 GB + extracted ~120 GB + installed ~60 GB + IP cache
  disk_type               = "pd-standard"   # bake VM only — Vivado install is CPU-bound, HDD is fine
  image_name              = "vivado-2024-2-{{timestamp}}"
  image_family            = "vivado-kiwisdr"
  ssh_username  = "packer"
  ssh_timeout   = "3h"
}

build {
  sources = ["source.googlecompute.vivado"]

  # System dependencies for Vivado 2024.2 on Ubuntu 22.04
  provisioner "shell" {
    inline = [
      # Wait for cloud-init / unattended-upgrades to release apt locks
      "while sudo fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do echo 'Waiting for apt lock...'; sleep 5; done",
      "sudo apt-get update",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \\",
      "  libtinfo5 libncurses5 libx11-6 libxrender1 libxtst6 libxi6 \\",
      "  libxrandr2 libfreetype6 libfontconfig1 git make rsync",
    ]
  }

  # Download installer with resumable/retry support, extract, then delete to free space
  provisioner "shell" {
    inline = [
      "set -e",
      "mkdir -p /tmp/vivado",
      "gsutil cp ${var.vivado_installer_gcs} /tmp/vivado/installer.tar",
      "tar xf /tmp/vivado/installer.tar -C /tmp/vivado && rm /tmp/vivado/installer.tar",
    ]
  }

  # Silent install config
  provisioner "file" {
    source      = "install_config.txt"
    destination = "/tmp/vivado/install_config.txt"
  }

  provisioner "shell" {
    inline = [
      "cd /tmp/vivado/FPGAs_AdaptiveSoCs_Unified_2024.2_* && \\",
      "  sudo ./xsetup \\",
      "    --agree XilinxEULA,3rdPartyEULA \\",
      "    --batch Install \\",
      "    --config /tmp/vivado/install_config.txt",
      "sudo rm -rf /tmp/vivado",
    ]
  }

  # Auto-source Vivado for all batch (non-interactive) shells
  provisioner "shell" {
    inline = [
      "echo 'source /tools/Xilinx/Vivado/2024.2/settings64.sh' | \\",
      "  sudo tee /etc/profile.d/vivado.sh",
      "sudo chmod +x /etc/profile.d/vivado.sh",
    ]
  }

  # Cable drivers (harmless if no board attached)
  provisioner "shell" {
    inline = [
      "sudo /tools/Xilinx/Vivado/2024.2/data/xicom/cable_drivers/lin64/install_script/install_drivers/install_drivers || true",
    ]
  }

  # Pre-compile Vivado IP cache so Cloud Batch jobs skip the ~30 min IP build step.
  # Vivado stores compiled IP in KiwiSDR/KiwiSDR.cache/ip/ (set via ip_output_repo in make_proj.tcl).
  # We run a one-time rx4_wf4 build here to warm the cache, then archive it to /opt/kiwisdr-ip-cache/.
  # Each build job restores the cache before invoking Vivado, so IP compilation is skipped entirely.
  provisioner "shell" {
    inline = ["mkdir -p /tmp/kiwi-warm"]
  }

  provisioner "file" {
    source      = "../verilog"
    destination = "/tmp/kiwi-warm/verilog"
  }

  provisioner "file" {
    source      = "../verilog.Vivado.2022.2.ip"
    destination = "/tmp/kiwi-warm/verilog.Vivado.2022.2.ip"
  }

  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; bash {{ .Path }}"
    inline = [
      "set -e",
      "source /tools/Xilinx/Vivado/2024.2/settings64.sh",

      # Set up project layout from /tmp/kiwi-warm/ — vivado and TCL files all run from here
      "cd /tmp/kiwi-warm",
      "mkdir -p KiwiSDR/import_srcs KiwiSDR/import_ip generated",
      "rsync -a verilog/ KiwiSDR/import_srcs/",
      "rsync -a verilog.Vivado.2022.2.ip/ KiwiSDR/import_ip/",
      "cp verilog/kiwi.tcl verilog/make_proj.tcl .",

      # Run vivado from /tmp/kiwi-warm/ as make_proj.tcl expects
      "time vivado -mode batch -source make_proj.tcl -tclargs --result_dir /tmp/kiwi-warm --rx4_wf4 || true",

      # Archive the IP cache
      "sudo mkdir -p /opt/kiwisdr-ip-cache",
      "sudo cp -r KiwiSDR/KiwiSDR.cache/ip /opt/kiwisdr-ip-cache/",
      "sudo chmod -R a+rX /opt/kiwisdr-ip-cache",

      # Clean up build artefacts — keep only the cache
      "rm -rf /tmp/kiwi-warm",
    ]
  }
}

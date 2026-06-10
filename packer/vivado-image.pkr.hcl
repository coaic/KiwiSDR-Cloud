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
  description = "gs:// URL of FPGAs_AdaptiveSoCs_Unified_2024.2_*.tar in your installer bucket. The installer must be obtained directly from AMD/Xilinx: https://www.xilinx.com/support/download/index.html/content/xilinx/en/downloadNav/vivado-design-suite/archive.html"
}

source "googlecompute" "vivado" {
  project_id              = var.project_id
  zone                    = var.zone
  source_image_family      = "ubuntu-pro-2004-lts"
  source_image_project_id  = ["ubuntu-os-pro-cloud"]
  machine_type            = "n2-standard-8"  # only used during image bake
  disk_size               = 300              # tar ~125 GB + extracted ~120 GB + installed ~60 GB
  disk_type               = "pd-standard"   # bake VM only — Vivado install is CPU-bound, HDD is fine
  image_name              = "vivado-2024-2-{{timestamp}}"
  image_family            = "vivado-2024-2"
  service_account_email   = "fpga-builder@${var.project_id}.iam.gserviceaccount.com"
  ssh_username  = "packer"
  ssh_timeout   = "3h"
}

build {
  sources = ["source.googlecompute.vivado"]

  # System dependencies for Vivado 2024.2 on Ubuntu 20.04
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

}

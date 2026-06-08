terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

# Enable Private Google Access so Batch VMs with no external IP can reach
# GCS, Cloud Logging, and the Batch agent endpoint.
resource "google_compute_subnetwork" "default" {
  name                     = "default"
  project                  = var.project_id
  region                   = var.region
  network                  = "projects/${var.project_id}/global/networks/default"
  ip_cidr_range            = var.ip_cidr_range
  private_ip_google_access = true
}

# Cloud Router + NAT so VMs with no external IP can reach the public internet
# (e.g. git clone from GitHub) while remaining unreachable inbound.
resource "google_compute_router" "default" {
  name    = "fpga-build-router"
  project = var.project_id
  region  = var.region
  network = "projects/${var.project_id}/global/networks/default"
}

resource "google_compute_router_nat" "default" {
  name                               = "fpga-build-nat"
  project                            = var.project_id
  router                             = google_compute_router.default.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

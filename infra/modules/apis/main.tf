terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

resource "google_project_service" "enabled" {
  for_each = toset(var.apis)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

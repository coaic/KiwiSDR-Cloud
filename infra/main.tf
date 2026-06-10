terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
  backend "gcs" {
    # bucket and prefix are injected at init time by tf.sh:
    #   ./tf.sh dev init
  }
}

provider "google" {
  project               = var.project_id
  region                = var.region
  user_project_override = true
  billing_project       = var.project_id
}

# Project number is GCP-assigned and globally unique — including it in bucket
# names prevents conflicts even if a project ID is later recycled by GCP.
data "google_project" "this" {}

locals {
  project_number        = data.google_project.this.number
  artifacts_bucket_name = "${var.project_id}-${local.project_number}-fpga-artifacts"
  installer_bucket_name = var.installer_bucket_name != "" ? var.installer_bucket_name : "${var.project_id}-${local.project_number}-fpga-installer"
}

module "apis" {
  source     = "./modules/apis"
  project_id = var.project_id
  apis       = var.apis
}

module "artifacts_bucket" {
  source         = "./modules/storage"
  bucket_name    = local.artifacts_bucket_name
  location       = var.region
  retention_days = var.artifact_retention_days

  depends_on = [module.apis]
}

module "installer_bucket" {
  source             = "./modules/storage"
  bucket_name        = local.installer_bucket_name
  location           = var.region
  retention_days     = 0
  versioning_enabled = false

  depends_on = [module.apis]
}

module "iam" {
  source                = "./modules/iam"
  project_id            = var.project_id
  artifacts_bucket_name = module.artifacts_bucket.bucket_name
  installer_bucket_name = module.installer_bucket.bucket_name
  submitter_email       = var.submitter_email

  depends_on = [module.apis]
}

module "networking" {
  source        = "./modules/networking"
  project_id    = var.project_id
  region        = var.region
  ip_cidr_range = var.subnet_cidr

  depends_on = [module.apis]
}

module "budget" {
  source          = "./modules/budget"
  count           = var.billing_account != "" ? 1 : 0
  project_id      = var.project_id
  billing_account = var.billing_account
  budget_usd      = var.budget_usd
  environment     = var.environment

  depends_on = [module.apis]
}

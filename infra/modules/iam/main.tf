terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

resource "google_service_account" "builder" {
  project      = var.project_id
  account_id   = "fpga-builder"
  display_name = "FPGA build VM (Batch agent + GCS writer)"
}

resource "google_storage_bucket_iam_member" "builder_writer" {
  bucket = var.artifacts_bucket_name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.builder.email}"
}

# Required for custom images: Batch agent on the VM must report back to the
# Batch control plane or jobs hang with "no VM has agent reporting correctly".
resource "google_project_iam_member" "builder_agent" {
  project = var.project_id
  role    = "roles/batch.agentReporter"
  member  = "serviceAccount:${google_service_account.builder.email}"
}

resource "google_project_iam_member" "builder_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.builder.email}"
}

resource "google_project_iam_member" "submitter_jobs_editor" {
  project = var.project_id
  role    = "roles/batch.jobsEditor"
  member  = "user:${var.submitter_email}"
}

# Required to submit a job that runs as the builder SA
resource "google_service_account_iam_member" "submitter_actas" {
  service_account_id = google_service_account.builder.name
  role               = "roles/iam.serviceAccountUser"
  member             = "user:${var.submitter_email}"
}

resource "google_storage_bucket_iam_member" "submitter_reader" {
  bucket = var.artifacts_bucket_name
  role   = "roles/storage.objectViewer"
  member = "user:${var.submitter_email}"
}

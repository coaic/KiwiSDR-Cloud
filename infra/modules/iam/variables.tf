variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "artifacts_bucket_name" {
  type        = string
  description = "GCS bucket name the builder SA needs write access to"
}

variable "submitter_email" {
  type        = string
  description = "User email that will submit Batch jobs (gets jobsEditor + serviceAccountUser)"
}

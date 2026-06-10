output "artifacts_bucket" {
  description = "GCS bucket name for build artifacts"
  value       = module.artifacts_bucket.bucket_name
}

output "artifacts_bucket_url" {
  description = "Full GCS URL for build artifacts"
  value       = module.artifacts_bucket.bucket_url
}

output "installer_bucket" {
  description = "GCS bucket name for the Vivado installer archive"
  value       = module.installer_bucket.bucket_name
}

output "installer_bucket_url" {
  description = "Full GCS URL for the Vivado installer bucket"
  value       = module.installer_bucket.bucket_url
}

output "builder_sa_email" {
  description = "Service account email used by Batch VMs"
  value       = module.iam.builder_sa_email
}

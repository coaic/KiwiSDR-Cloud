output "artifacts_bucket" {
  value = module.artifacts_bucket.bucket_name
}

output "artifacts_bucket_url" {
  value = module.artifacts_bucket.bucket_url
}

output "installer_bucket" {
  value = module.installer_bucket.bucket_name
}

output "builder_sa_email" {
  value = module.iam.builder_sa_email
}

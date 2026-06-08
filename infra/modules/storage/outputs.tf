output "bucket_name" {
  value = google_storage_bucket.this.name
}

output "bucket_url" {
  value = "gs://${google_storage_bucket.this.name}"
}

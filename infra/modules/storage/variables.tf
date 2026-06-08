variable "bucket_name" {
  type        = string
  description = "GCS bucket name"
}

variable "location" {
  type        = string
  description = "GCS bucket location (region or multi-region)"
}

variable "retention_days" {
  type        = number
  description = "Days before objects are auto-deleted. 0 disables the lifecycle rule."
  default     = 0
}

variable "versioning_enabled" {
  type        = bool
  description = "Enable object versioning (recommended for state buckets)"
  default     = false
}

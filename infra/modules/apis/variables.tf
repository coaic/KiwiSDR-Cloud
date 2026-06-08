variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "apis" {
  type        = list(string)
  description = "List of GCP API service names to enable"
}

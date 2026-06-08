variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "region" {
  type        = string
  description = "Region containing the default subnet"
}

variable "ip_cidr_range" {
  type        = string
  description = "IP CIDR range of the default subnet (must match existing range)"
  default     = "10.152.0.0/20"
}

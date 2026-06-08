variable "project_id" {
  type        = string
  description = "GCP project ID to scope the budget to"
}

variable "billing_account" {
  type        = string
  description = "GCP billing account ID (format: XXXXXX-XXXXXX-XXXXXX)"
}

variable "budget_usd" {
  type        = number
  description = "Monthly budget cap in USD"
  default     = 20
}

variable "environment" {
  type        = string
  description = "Environment label used in the budget display name"
}

variable "currency_code" {
  type        = string
  description = "ISO 4217 currency code matching your billing account currency (e.g. AUD, USD)"
  default     = "AUD"
}

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

data "google_project" "current" {
  project_id = var.project_id
}

resource "google_billing_budget" "fpga" {
  billing_account = var.billing_account
  display_name    = "FPGA build budget - ${var.environment}"

  budget_filter {
    projects = ["projects/${data.google_project.current.number}"]
  }

  amount {
    specified_amount {
      currency_code = var.currency_code
      units         = tostring(var.budget_usd)
    }
  }

  threshold_rules { threshold_percent = 0.5 }
  threshold_rules { threshold_percent = 0.9 }
  threshold_rules { threshold_percent = 1.0 }
}

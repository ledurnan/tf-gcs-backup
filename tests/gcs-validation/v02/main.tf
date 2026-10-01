# Phase B onwards: the same host upgraded to this working tree's modules,
# plus a fresh host ("validation") with one unlocked and one lockable
# tier. Shares its local state with ../v01.

terraform {
  required_version = ">= 1.7"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.0, < 9.0"
    }
  }

  backend "local" {
    path = "../.state/terraform.tfstate"
  }
}

provider "google" {
  project = var.project
}

module "writer_role" {
  source  = "../../../modules/project-role"
  project = var.project
  role_id = var.role_id
  title   = "tf-gcs-backup validation writer (disposable)"
}

module "upgraded" {
  source             = "../../../modules/backup-target"
  project            = var.project
  location           = var.location
  bucket_name_prefix = "${var.name_prefix}-upg"
  service_account_id = "${var.sa_prefix}-upg"
  role_name          = module.writer_role.role_name
  labels             = var.labels
  tiers              = [{ name = "daily", retain_days = 1 }]
}

module "validation" {
  source             = "../../../modules/backup-target"
  project            = var.project
  location           = var.location
  bucket_name_prefix = "${var.name_prefix}-val"
  service_account_id = "${var.sa_prefix}-val"
  role_name          = module.writer_role.role_name
  labels             = var.labels
  tiers = [
    { name = "daily", retain_days = 1 },
    { name = "locked", retain_days = 1, locked = var.lock_locked_tier },
  ]
}

output "validation" {
  value = {
    buckets               = module.validation.buckets
    service_account_email = module.validation.service_account_email
  }
}

output "upgraded" {
  value = {
    buckets               = module.upgraded.buckets
    service_account_email = module.upgraded.service_account_email
  }
}

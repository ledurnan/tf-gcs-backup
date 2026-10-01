# Phase A: a host as v0.1 left it, from the released v0.1.0 modules.
# Shares its local state with ../v02, which upgrades it.

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
  source  = "git::https://github.com/ledurnan/tf-gcs-backup.git//modules/project-role?ref=v0.1.0"
  project = var.project
  role_id = var.role_id
  title   = "tf-gcs-backup validation writer (disposable)"
}

module "upgraded" {
  source             = "git::https://github.com/ledurnan/tf-gcs-backup.git//modules/backup-target?ref=v0.1.0"
  project            = var.project
  location           = var.location
  bucket_name        = "${var.name_prefix}-upg"
  service_account_id = "${var.sa_prefix}-upg"
  role_name          = module.writer_role.role_name
  labels             = var.labels
  tiers              = [{ name = "daily", retain_days = 1 }]
}

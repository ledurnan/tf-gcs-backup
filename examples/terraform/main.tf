# Example: one Google Cloud project holding backups for two hosts with
# very different data. Placeholders throughout; copy this into your own
# repository and give it your own values and state backend.
#
# In your own repository, source the modules from a pinned tag:
#   source = "git::https://github.com/ledurnan/tf-gcs-backup.git//modules/project-role?ref=v0.2.0"
#   source = "git::https://github.com/ledurnan/tf-gcs-backup.git//modules/backup-target?ref=v0.2.0"

terraform {
  required_version = ">= 1.7"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.0, < 9.0"
    }
  }
}

provider "google" {
  project = var.project
}

# Once per project: the write-only role every host is bound to.
module "writer_role" {
  source  = "../../modules/project-role"
  project = var.project
}

# A host whose irreplaceable state is a few megabytes of configuration.
# Long history is cheap here and holds no personal data.
module "config_host" {
  source             = "../../modules/backup-target"
  project            = var.project
  location           = var.location
  bucket_name_prefix = "${var.name_prefix}-config-host"
  service_account_id = "${var.name_prefix}-config-host"
  role_name          = module.writer_role.role_name
  # One bucket per tier: <prefix>-daily, <prefix>-weekly, <prefix>-monthly.
  # Set locked = true on a tier only once a restore test has passed:
  # locking can't be undone.
  tiers = [
    { name = "daily", retain_days = 7 },
    { name = "weekly", retain_days = 90 },
    { name = "monthly", retain_days = 365 },
  ]
}

# A host with a database holding personal data, where the service has
# promised to keep backups for no more than 35 days.
module "database_host" {
  source             = "../../modules/backup-target"
  project            = var.project
  location           = var.location
  bucket_name_prefix = "${var.name_prefix}-database-host"
  service_account_id = "${var.name_prefix}-database-host"
  role_name          = module.writer_role.role_name
  tiers = [
    { name = "daily", retain_days = 7 },
    { name = "weekly", retain_days = 28 },
  ]
  # 28 + 1 day of slack keeps every object inside the 35-day promise.
  lifecycle_slack_days = 1
}

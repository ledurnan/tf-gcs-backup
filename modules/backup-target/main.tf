# The receiving side of one backed-up host: a bucket it can add to but
# never delete from, per-object retention, one expiry rule per tier, and
# a service account bound to the write-only role on this bucket only.

locals {
  # Minimum storage durations GCS bills for. Deleting earlier is charged
  # as if the object had been kept for the full minimum.
  min_storage_days = {
    STANDARD = 0
    NEARLINE = 30
    COLDLINE = 90
    ARCHIVE  = 365
  }

  tiers = [
    for t in var.tiers : {
      name               = t.name
      retain_days        = t.retain_days
      lifecycle_age_days = t.retain_days + var.lifecycle_slack_days
    }
  ]
}

resource "google_storage_bucket" "this" {
  project       = var.project
  name          = var.bucket_name
  location      = var.location
  storage_class = var.storage_class
  labels        = var.labels

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # Per-object retention can only be switched on when a bucket is
  # created. It lets the host lock each object until its retain-until.
  enable_object_retention = true

  # Two independent guards: this bucket holds objects that can't be
  # deleted, so Terraform must never try.
  force_destroy   = false
  deletion_policy = "PREVENT"

  dynamic "lifecycle_rule" {
    for_each = local.tiers

    content {
      action {
        type = "Delete"
      }

      condition {
        age            = lifecycle_rule.value.lifecycle_age_days
        matches_prefix = ["${lifecycle_rule.value.name}/"]
      }
    }
  }

  dynamic "soft_delete_policy" {
    for_each = var.soft_delete_retention_seconds == null ? [] : [var.soft_delete_retention_seconds]

    content {
      retention_duration_seconds = soft_delete_policy.value
    }
  }

  lifecycle {
    prevent_destroy = true

    precondition {
      condition = alltrue([
        for t in var.tiers : t.retain_days >= local.min_storage_days[var.storage_class]
      ])
      error_message = "Every tier must retain at least the storage class's minimum duration (${local.min_storage_days[var.storage_class]} days for ${var.storage_class}), or each expiry is billed as early deletion. Use STANDARD for short tiers."
    }
  }
}

resource "google_service_account" "writer" {
  project      = var.project
  account_id   = var.service_account_id
  display_name = coalesce(var.service_account_display_name, "Off-site backup writer for ${var.bucket_name}")
  description  = "Writes encrypted backups to gs://${var.bucket_name}. Cannot delete."
}

# Bound on the bucket, not the project, so the credential reaches only
# this host's backups.
resource "google_storage_bucket_iam_member" "writer" {
  bucket = google_storage_bucket.this.name
  role   = var.role_name
  member = "serviceAccount:${google_service_account.writer.email}"
}

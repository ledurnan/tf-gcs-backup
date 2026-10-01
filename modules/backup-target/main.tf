# The receiving side of one backed-up host: one bucket per retention
# tier, each with a bucket retention policy and an expiry rule covering
# every object in it, and a service account bound to the write-only role
# on those buckets only.
#
# Retention is set here, on the bucket, never by the host (ADR 0007). The
# host can't choose how long an object is kept, and nothing it writes can
# outlive its tier.

locals {
  # Minimum storage durations GCS bills for. Deleting earlier is charged
  # as if the object had been kept for the full minimum.
  min_storage_days = {
    STANDARD = 0
    NEARLINE = 30
    COLDLINE = 90
    ARCHIVE  = 365
  }

  tiers = {
    for t in var.tiers : t.name => {
      name               = t.name
      retain_days        = t.retain_days
      lifecycle_age_days = t.retain_days + var.lifecycle_slack_days
      locked             = t.locked
      bucket             = "${var.bucket_name_prefix}-${t.name}"
    }
  }
}

resource "google_storage_bucket" "tier" {
  for_each = local.tiers

  project       = var.project
  name          = each.value.bucket
  location      = var.location
  storage_class = var.storage_class
  labels        = merge(var.labels, { backup-tier = each.key })

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # Per-object retention stays off: with it, whoever can write can also
  # choose an object's retention, and a compromised host could lock junk
  # in place for as long as it liked.
  enable_object_retention = false

  # No object can be deleted or replaced until it is retain_days old.
  # Unlocked, an operator with storage.buckets.update can shorten or
  # remove the policy (and then delete). Locked, nobody can, and the
  # period can only ever be lengthened.
  retention_policy {
    retention_period = tostring(each.value.retain_days * 86400)
    is_locked        = each.value.locked
  }

  # No prefix: every object in the bucket expires, whatever its name.
  lifecycle_rule {
    action {
      type = "Delete"
    }

    condition {
      age = each.value.lifecycle_age_days
    }
  }

  dynamic "soft_delete_policy" {
    for_each = var.soft_delete_retention_seconds == null ? [] : [var.soft_delete_retention_seconds]

    content {
      retention_duration_seconds = soft_delete_policy.value
    }
  }

  # Two independent guards: this bucket holds objects that can't be
  # deleted, so Terraform must never try.
  force_destroy   = false
  deletion_policy = "PREVENT"

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = each.value.retain_days >= local.min_storage_days[var.storage_class]
      error_message = "Tier ${each.key} keeps objects ${each.value.retain_days} days, under ${var.storage_class}'s minimum of ${local.min_storage_days[var.storage_class]}: each expiry would be billed as early deletion. Use STANDARD for short tiers."
    }

    precondition {
      condition     = length(each.value.bucket) <= 63
      error_message = "Bucket name ${each.value.bucket} is longer than 63 characters: shorten bucket_name_prefix or the tier name."
    }
  }
}

resource "google_service_account" "writer" {
  project      = var.project
  account_id   = var.service_account_id
  display_name = coalesce(var.service_account_display_name, "Off-site backup writer for ${var.bucket_name_prefix}")
  description  = "Writes encrypted backups to gs://${var.bucket_name_prefix}-<tier>. Cannot delete or set retention."
}

# Bound on each tier's bucket, not the project, so the credential reaches
# only this host's backups.
resource "google_storage_bucket_iam_member" "writer" {
  for_each = google_storage_bucket.tier

  bucket = each.value.name
  role   = var.role_name
  member = "serviceAccount:${google_service_account.writer.email}"
}

# v0.1 kept every tier in one bucket with per-object retention. Upgrading
# forgets that bucket rather than destroying it: its objects stay under
# their own retention and expire by its own rules. See
# docs/upgrading-to-v0.2.md.
removed {
  from = google_storage_bucket.this

  lifecycle {
    destroy = false
  }
}

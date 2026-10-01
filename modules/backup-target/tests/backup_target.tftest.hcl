# Plans against a mock provider: no Google Cloud access needed.
mock_provider "google" {}

variables {
  project            = "example-project"
  bucket_name_prefix = "example-host-backup"
  location           = "europe-west2"
  role_name          = "projects/example-project/roles/offsiteBackupWriter"
  service_account_id = "example-host-backup"
  tiers = [
    { name = "daily", retain_days = 7 },
    { name = "weekly", retain_days = 35, locked = true },
  ]
}

run "one_bucket_per_tier" {
  command = plan

  assert {
    condition     = toset(keys(google_storage_bucket.tier)) == toset(["daily", "weekly"])
    error_message = "Expected one bucket per tier."
  }

  assert {
    condition     = google_storage_bucket.tier["daily"].name == "example-host-backup-daily" && google_storage_bucket.tier["weekly"].name == "example-host-backup-weekly"
    error_message = "Each tier's bucket must be <bucket_name_prefix>-<tier>."
  }

  assert {
    condition     = output.buckets == { daily = "example-host-backup-daily", weekly = "example-host-backup-weekly" }
    error_message = "The buckets output must map each tier to its bucket."
  }

  assert {
    condition     = google_storage_bucket.tier["weekly"].labels["backup-tier"] == "weekly"
    error_message = "Each bucket must be labelled with its tier."
  }
}

run "retention_is_set_on_the_bucket" {
  command = plan

  assert {
    condition     = one(google_storage_bucket.tier["daily"].retention_policy).retention_period == "604800" && one(google_storage_bucket.tier["weekly"].retention_policy).retention_period == "3024000"
    error_message = "Each bucket's retention period must be its tier's retain_days, in seconds."
  }

  assert {
    condition     = one(google_storage_bucket.tier["daily"].retention_policy).is_locked == false && one(google_storage_bucket.tier["weekly"].retention_policy).is_locked == true
    error_message = "A tier is locked only when it says so."
  }

  assert {
    condition     = google_storage_bucket.tier["daily"].enable_object_retention == false && google_storage_bucket.tier["weekly"].enable_object_retention == false
    error_message = "Per-object retention must be off: the host must not choose retention."
  }
}

run "every_object_expires" {
  command = plan

  assert {
    condition     = length(google_storage_bucket.tier["daily"].lifecycle_rule) == 1 && length(google_storage_bucket.tier["weekly"].lifecycle_rule) == 1
    error_message = "Expected one expiry rule per bucket."
  }

  assert {
    condition     = one(google_storage_bucket.tier["daily"].lifecycle_rule[0].condition).age == 8 && one(google_storage_bucket.tier["weekly"].lifecycle_rule[0].condition).age == 36
    error_message = "Each rule's age must be retain_days plus the default slack of 1."
  }

  assert {
    condition     = length(coalesce(one(google_storage_bucket.tier["daily"].lifecycle_rule[0].condition).matches_prefix, [])) == 0
    error_message = "The expiry rule must have no prefix, so it covers every object in the bucket."
  }

  assert {
    condition     = output.tiers[1] == { name = "weekly", retain_days = 35, lifecycle_age_days = 36, locked = true, bucket = "example-host-backup-weekly" }
    error_message = "The tier contract output must carry the expiry age, the lock and the bucket."
  }
}

run "buckets_are_locked_down" {
  command = plan

  assert {
    condition     = alltrue([for b in google_storage_bucket.tier : b.deletion_policy == "PREVENT" && b.force_destroy == false])
    error_message = "Every bucket must be protected from deletion."
  }

  assert {
    condition     = alltrue([for b in google_storage_bucket.tier : b.public_access_prevention == "enforced" && b.uniform_bucket_level_access == true])
    error_message = "Public access must be prevented and access uniform."
  }

  assert {
    condition     = toset(keys(google_storage_bucket_iam_member.writer)) == toset(["daily", "weekly"]) && alltrue([for m in google_storage_bucket_iam_member.writer : m.role == var.role_name])
    error_message = "The host must be bound to the write-only role on each of its tier buckets."
  }
}

run "slack_is_configurable" {
  command = plan

  variables {
    lifecycle_slack_days = 0
  }

  assert {
    condition     = one(google_storage_bucket.tier["daily"].lifecycle_rule[0].condition).age == 7
    error_message = "With no slack, the rule's age equals retain_days."
  }
}

run "soft_delete_unmanaged_by_default" {
  command = plan

  assert {
    condition     = length(google_storage_bucket.tier["daily"].soft_delete_policy) == 0
    error_message = "soft_delete_policy must be left alone unless asked for."
  }
}

run "soft_delete_when_set" {
  command = plan

  variables {
    soft_delete_retention_seconds = 0
  }

  assert {
    condition     = one(google_storage_bucket.tier["weekly"].soft_delete_policy).retention_duration_seconds == 0
    error_message = "soft_delete_retention_seconds must reach every tier's bucket."
  }
}

run "rejects_empty_tiers" {
  command = plan

  variables {
    tiers = []
  }

  expect_failures = [var.tiers]
}

run "rejects_duplicate_tier_names" {
  command = plan

  variables {
    tiers = [
      { name = "daily", retain_days = 7 },
      { name = "daily", retain_days = 30 },
    ]
  }

  expect_failures = [var.tiers]
}

run "rejects_fractional_retention" {
  command = plan

  variables {
    tiers = [{ name = "daily", retain_days = 1.5 }]
  }

  expect_failures = [var.tiers]
}

run "rejects_retention_past_the_policy_limit" {
  command = plan

  variables {
    tiers = [{ name = "forever", retain_days = 36501 }]
  }

  expect_failures = [var.tiers]
}

run "rejects_a_bucket_name_over_63_characters" {
  command = plan

  variables {
    bucket_name_prefix = "a-very-long-bucket-name-prefix-that-leaves-no-room"
    tiers              = [{ name = "a-long-tier-name", retain_days = 7 }]
  }

  expect_failures = [google_storage_bucket.tier["a-long-tier-name"]]
}

run "rejects_cold_class_shorter_than_its_minimum" {
  command = plan

  variables {
    storage_class = "NEARLINE"
  }

  expect_failures = [google_storage_bucket.tier["daily"]]
}

run "accepts_cold_class_when_every_tier_is_long_enough" {
  command = plan

  variables {
    storage_class = "NEARLINE"
    tiers         = [{ name = "monthly", retain_days = 365 }]
  }

  assert {
    condition     = google_storage_bucket.tier["monthly"].storage_class == "NEARLINE"
    error_message = "A cold class is fine when every tier outlives its minimum."
  }
}

run "rejects_a_bare_role_id" {
  command = plan

  variables {
    role_name = "offsiteBackupWriter"
  }

  expect_failures = [var.role_name]
}

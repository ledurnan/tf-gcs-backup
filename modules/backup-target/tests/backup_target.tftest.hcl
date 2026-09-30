# Plans against a mock provider: no Google Cloud access needed.
mock_provider "google" {}

variables {
  project            = "example-project"
  bucket_name        = "example-host-backup"
  location           = "europe-west2"
  role_name          = "projects/example-project/roles/offsiteBackupWriter"
  service_account_id = "example-host-backup"
  tiers = [
    { name = "daily", retain_days = 7 },
    { name = "weekly", retain_days = 35 },
  ]
}

run "one_expiry_rule_per_tier" {
  command = plan

  assert {
    condition     = length(google_storage_bucket.this.lifecycle_rule) == 2
    error_message = "Expected one lifecycle rule per tier."
  }

  assert {
    condition     = one(google_storage_bucket.this.lifecycle_rule[0].condition).age == 8 && one(google_storage_bucket.this.lifecycle_rule[1].condition).age == 36
    error_message = "Each rule's age must be retain_days plus the default slack of 1."
  }

  assert {
    condition     = one(google_storage_bucket.this.lifecycle_rule[1].condition).matches_prefix == tolist(["weekly/"])
    error_message = "Each rule must match its tier's prefix, with a trailing slash."
  }

  assert {
    condition     = output.tiers[1] == { name = "weekly", retain_days = 35, lifecycle_age_days = 36 }
    error_message = "The tier contract output must carry the expiry age."
  }
}

run "bucket_is_locked_down" {
  command = plan

  assert {
    condition     = google_storage_bucket.this.enable_object_retention == true
    error_message = "Per-object retention must be on."
  }

  assert {
    condition     = google_storage_bucket.this.deletion_policy == "PREVENT" && google_storage_bucket.this.force_destroy == false
    error_message = "The bucket must be protected from deletion."
  }

  assert {
    condition     = google_storage_bucket.this.public_access_prevention == "enforced" && google_storage_bucket.this.uniform_bucket_level_access == true
    error_message = "Public access must be prevented and access uniform."
  }

  assert {
    condition     = google_storage_bucket_iam_member.writer.role == var.role_name
    error_message = "The host must be bound to the write-only role on its bucket."
  }
}

run "slack_is_configurable" {
  command = plan

  variables {
    lifecycle_slack_days = 0
  }

  assert {
    condition     = one(google_storage_bucket.this.lifecycle_rule[0].condition).age == 7
    error_message = "With no slack, the rule's age equals retain_days."
  }
}

run "soft_delete_unmanaged_by_default" {
  command = plan

  assert {
    condition     = length(google_storage_bucket.this.soft_delete_policy) == 0
    error_message = "soft_delete_policy must be left alone unless asked for."
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

run "rejects_cold_class_shorter_than_its_minimum" {
  command = plan

  variables {
    storage_class = "NEARLINE"
  }

  expect_failures = [google_storage_bucket.this]
}

run "accepts_cold_class_when_every_tier_is_long_enough" {
  command = plan

  variables {
    storage_class = "NEARLINE"
    tiers         = [{ name = "monthly", retain_days = 365 }]
  }

  assert {
    condition     = google_storage_bucket.this.storage_class == "NEARLINE"
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

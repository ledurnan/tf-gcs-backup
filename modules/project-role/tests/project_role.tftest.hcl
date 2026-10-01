mock_provider "google" {}

variables {
  project = "example-project"
}

run "grants_write_only_permissions" {
  command = plan

  assert {
    condition     = length([for p in google_project_iam_custom_role.writer.permissions : p if strcontains(p, "delete")]) == 0
    error_message = "The role must never grant a delete permission."
  }

  assert {
    condition     = !contains(google_project_iam_custom_role.writer.permissions, "storage.objects.setRetention")
    error_message = "The host must never choose retention (ADR 0007): no setRetention."
  }

  assert {
    condition     = length([for p in google_project_iam_custom_role.writer.permissions : p if strcontains(p, "update") || strcontains(p, "setIamPolicy") || strcontains(p, "override")]) == 0
    error_message = "The role must never change objects, buckets, access or retention."
  }

  assert {
    condition     = toset(google_project_iam_custom_role.writer.permissions) == toset(["storage.objects.create", "storage.objects.get", "storage.objects.list", "storage.buckets.get"])
    error_message = "The role grants exactly create, get and list on objects, and get on buckets (for the tier contract)."
  }
}

run "role_name_output_is_the_full_name" {
  command = plan

  assert {
    condition     = google_project_iam_custom_role.writer.role_id == "offsiteBackupWriter"
    error_message = "Default role_id changed; that breaks existing consumers."
  }
}

run "rejects_an_invalid_role_id" {
  command = plan

  variables {
    role_id = "no spaces!"
  }

  expect_failures = [var.role_id]
}

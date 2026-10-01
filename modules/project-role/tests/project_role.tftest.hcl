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

run "emergency_role_can_only_clear" {
  command = plan

  assert {
    condition     = toset(google_project_iam_custom_role.emergency.permissions) == toset(["storage.buckets.get", "storage.buckets.update", "storage.objects.list", "storage.objects.get", "storage.objects.delete"])
    error_message = "The emergency role grants exactly: read and update the bucket (its retention policy), list, get and delete objects."
  }

  assert {
    condition     = google_project_iam_custom_role.emergency.role_id == "offsiteBackupEmergency"
    error_message = "Default emergency_role_id changed; that breaks existing consumers."
  }
}

run "rejects_an_invalid_emergency_role_id" {
  command = plan

  variables {
    emergency_role_id = "no spaces!"
  }

  expect_failures = [var.emergency_role_id]
}

run "role_names_wait_for_the_roles_to_be_usable" {
  command = plan

  assert {
    condition     = time_sleep.roles_usable.create_duration == "60s"
    error_message = "Bindings must wait for a new role to take effect."
  }

}

# Applied against the mock provider: nothing reaches Google Cloud, and the
# wait is zero.
run "role_name_outputs_come_through_the_wait" {
  command = apply

  variables {
    role_propagation_seconds = 0
  }

  assert {
    condition     = output.role_name == google_project_iam_custom_role.writer.name && output.emergency_role_name == google_project_iam_custom_role.emergency.name
    error_message = "The role name outputs must be the roles' names, passed through the wait."
  }
}

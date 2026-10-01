# The write-only role every backed-up host is bound to, and the
# emergency role an operator can be given to clear an unlocked tier.
#
# A predefined role doesn't fit: roles/storage.objectCreator can't read
# back what it wrote, so a host couldn't verify its own upload, and
# roles/storage.objectAdmin carries storage.objects.delete, which is
# exactly what must never be on a host that can be compromised.
#
# The permission list is fixed here, not an input. Widening it is a
# change to this pattern, reviewed here, not a per-consumer choice.

locals {
  permissions = [
    # Upload, read back to verify, list to prove the credential works.
    "storage.objects.create",
    "storage.objects.get",
    "storage.objects.list",
    # Read each tier bucket's retention policy and lifecycle rules, so the
    # host can refuse to upload when its tiers disagree (the tier
    # contract).
    "storage.buckets.get",
  ]

  # Never on a host that can be compromised: deleting, changing objects
  # or buckets, choosing retention (ADR 0007), or changing who has access.
  forbidden = [
    for p in local.permissions : p
    if length(regexall("delete|update|setRetention|overrideUnlockedRetention|setIamPolicy", p)) > 0
  ]

  # Emergency access to an unlocked tier (ADR 0008): remove or shorten
  # the bucket's retention policy, then delete what shouldn't be there.
  # objects.get because gcloud reads an object's metadata before deleting
  # it; it also allows downloading, but every object is age-encrypted and
  # unreadable without the operators' private keys. Nothing that adds
  # data or changes access. A locked tier's policy can't be removed by
  # anyone, so this does nothing there.
  emergency_permissions = [
    "storage.buckets.get",
    "storage.buckets.update",
    "storage.objects.list",
    "storage.objects.get",
    "storage.objects.delete",
  ]

  emergency_forbidden = [
    for p in local.emergency_permissions : p
    if length(regexall("IamPolicy|objects\\.(create|update|setRetention)|overrideUnlockedRetention", p)) > 0
  ]
}

resource "google_project_iam_custom_role" "writer" {
  project     = var.project
  role_id     = var.role_id
  title       = var.title
  description = "Write-only access for off-site backups: create, read back and list. Never delete, never set retention."
  permissions = local.permissions

  lifecycle {
    precondition {
      condition     = length(local.forbidden) == 0
      error_message = "The backup writer role must never grant ${join(", ", local.forbidden)}: a compromised host could erase its backups, change them, or choose how long junk is kept."
    }
  }
}

resource "google_project_iam_custom_role" "emergency" {
  project     = var.project
  role_id     = var.emergency_role_id
  title       = var.emergency_title
  description = "Emergency access to unlocked backup tiers: remove or shorten the retention policy, then delete objects. Never add objects or change access."
  permissions = local.emergency_permissions

  lifecycle {
    precondition {
      condition     = length(local.emergency_forbidden) == 0
      error_message = "The emergency role must never grant ${join(", ", local.emergency_forbidden)}: it is for removing backups from an unlocked tier, not adding them or granting access."
    }
  }
}

# A custom role isn't usable the moment it's created: binding it straight
# away fails with "does not exist in the resource's hierarchy". The role
# names are output through this, so every binding that uses them waits
# until a new role has had time to take effect. It only waits when a role
# is created or renamed, never on later applies.
resource "time_sleep" "roles_usable" {
  create_duration = "${var.role_propagation_seconds}s"

  triggers = {
    writer    = google_project_iam_custom_role.writer.name
    emergency = google_project_iam_custom_role.emergency.name
  }
}

# The write-only role every backed-up host is bound to.
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

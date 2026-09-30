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
    # Set each object's retain-until at upload.
    "storage.objects.setRetention",
    # Read the bucket's lifecycle rules, so the host can refuse to upload
    # when its tiers disagree with the bucket's (the tier contract).
    "storage.buckets.get",
  ]
}

resource "google_project_iam_custom_role" "writer" {
  project     = var.project
  role_id     = var.role_id
  title       = var.title
  description = "Write-only access for off-site backups: create, read back, list and set retention. Never delete."
  permissions = local.permissions

  lifecycle {
    precondition {
      condition     = length([for p in local.permissions : p if strcontains(p, "delete")]) == 0
      error_message = "The backup writer role must never grant a delete permission: a compromised host could then erase its own backups."
    }
  }
}

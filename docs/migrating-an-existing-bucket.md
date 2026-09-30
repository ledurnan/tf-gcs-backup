# Adopting an existing bucket

For a bucket (and role, service account and binding) built before this
pattern, for example by `gcloud` or an older Ansible role. **The bucket
must be imported, never recreated:** it likely holds locked objects that
can't be deleted, so Terraform replacing it would fail at best.

## 1. Write the module call to match what exists

Use the existing names exactly: `bucket_name`, `service_account_id`, the
role's `role_id`, the location, the storage class, and the same tiers and
slack as the live lifecycle rules. Read them back first:

```bash
gcloud storage buckets describe gs://<bucket> --format=json
gcloud iam roles describe <role_id> --project=<project>
```

## 2. Import

```hcl
import {
  to = module.writer_role.google_project_iam_custom_role.writer
  id = "projects/<project>/roles/<role_id>"
}

import {
  to = module.host_a.google_storage_bucket.this
  id = "<project>/<bucket>"
}

import {
  to = module.host_a.google_service_account.writer
  id = "projects/<project>/serviceAccounts/<account_id>@<project>.iam.gserviceaccount.com"
}

import {
  to = module.host_a.google_storage_bucket_iam_member.writer
  id = "b/<bucket> projects/<project>/roles/<role_id> serviceAccount:<account_id>@<project>.iam.gserviceaccount.com"
}
```

## 3. Plan, and read it

```bash
terraform plan
```

**Stop if the plan replaces or destroys anything.** A `-/+` or
`must be replaced` on the bucket means a setting differs that can't
change in place (for example `location`, or per-object retention). Fix
the module call to match the live bucket, not the other way round.

Expected, and safe, in-place changes:

- the custom role gains `storage.buckets.get` (the tier contract needs
  it) if it predates it;
- `deletion_policy` is set to `PREVENT` (this is state-only);
- lifecycle rules are reordered or their ages adjusted, if the old
  configuration differed.

Apply only once every change in the plan is one you expected.

## 4. Switch the host to the new role

The new role installs its own files (`/usr/local/sbin/offsite-backup`,
`/etc/offsite-backup/backup.conf`, …) and reuses the unit names
`offsite-backup.service` and `.timer`. Keep the host's object layout
(`<tier>/<prefix>/<date>.tar.age`) by setting `offsite_backup_prefix` to
the prefix it already uses, so existing and new objects sit together.

After applying, remove anything the old implementation left that the new
one doesn't use (an old script name, an old environment file), then run
one backup by hand and a restore test before leaving it to the timer.

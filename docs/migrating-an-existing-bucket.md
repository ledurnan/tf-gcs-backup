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

Read back what the host's service account can already do, too. Terraform
will manage one grant (the writer role, on this bucket) and **will not
show or remove any other**: a grant made before this pattern stays in
force after the import, outside the plan.

```bash
gcloud storage buckets get-iam-policy gs://<bucket>
gcloud projects get-iam-policy <project> \
  --flatten='bindings[].members' \
  --filter='bindings.members:serviceAccount:<account_id>@<project>.iam.gserviceaccount.com' \
  --format='table(bindings.role)'
gcloud iam service-accounts keys list \
  --iam-account=<account_id>@<project>.iam.gserviceaccount.com --managed-by=user
```

The account should hold the writer role on its own bucket and nothing
else: no other role on the bucket (`roles/storage.objectAdmin` and the
`legacy` bucket roles can delete), and no role on the project, which
would reach every bucket in it. Note any you find, and any key you don't
recognise; they are removed in step 5. The project policy needs a
project owner to read it: the Terraform service account can't.

If several hosts share the bucket, importing it for one of them leaves
the others' access in place. Give each its own bucket
([ADR 0001](adr/0001-one-bucket-per-host.md)).

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
- the custom role loses any permission this pattern doesn't grant, such
  as `storage.objects.delete`. That is the point: don't change the
  module call to keep it;
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

## 5. Remove what the old setup granted

As a project owner, remove every grant found in step 1 other than the
writer role on the host's own bucket, and delete every key other than
the one the host now uses:

```bash
gcloud storage buckets remove-iam-policy-binding gs://<bucket> \
  --member=serviceAccount:<account_id>@<project>.iam.gserviceaccount.com --role=<old role>
gcloud projects remove-iam-policy-binding <project> \
  --member=serviceAccount:<account_id>@<project>.iam.gserviceaccount.com --role=<old role>
gcloud iam service-accounts keys delete <key id> \
  --iam-account=<account_id>@<project>.iam.gserviceaccount.com
```

Then repeat the three read-back commands from step 1 and check the
account holds the writer role on its own bucket, one key, and nothing
else. Until it does, a compromised host may still be able to delete its
backups.

Objects the old implementation wrote keep whatever retention it gave
them, which may be none. They are protected by the host having no delete
permission, not by retention.

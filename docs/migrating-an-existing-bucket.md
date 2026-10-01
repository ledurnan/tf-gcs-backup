# Adopting an existing setup

For a bucket, role and service account built before this pattern, for
example by `gcloud` or an older Ansible role. Upgrading from v0.1 of
this repository is covered in [`upgrading-to-v0.2.md`](upgrading-to-v0.2.md)
instead.

**Don't adopt the old bucket. Leave it where it is.** Each tier is now a
bucket of its own with a bucket retention policy
([ADR 0007](adr/0007-bucket-retention-policy-per-tier.md)), and an
existing bucket that holds several tiers, or uses per-object retention,
can't become one. It probably holds locked objects too, so it can't be
replaced either. New backups go to new tier buckets, and the old bucket
ages out.

What's worth importing is the service account, so the host's existing
key keeps working, and the custom role, if it has the same ID.

## 1. Write the module call

Use the existing `service_account_id`. If the existing role's ID ends in
`Writer`, you can keep it by setting `role_id_prefix` to the part before
that; otherwise the module creates a new role. Choose a `bucket_name_prefix` whose tier buckets
(`<prefix>-<tier>`) don't exist yet. Read the existing names first:

```bash
gcloud iam service-accounts list --project=<project>
gcloud iam roles describe <role_id> --project=<project>
```

## 2. Import

```hcl
import {
  to = module.writer_role.google_project_iam_custom_role.writer
  id = "projects/<project>/roles/<role_id>"
}

import {
  to = module.host_a.google_service_account.writer
  id = "projects/<project>/serviceAccounts/<account_id>@<project>.iam.gserviceaccount.com"
}
```

## 3. Plan, and read it

```bash
terraform plan
```

Expected:

- the tier buckets and their bindings **created**;
- the service account **unchanged** (it may update in place, for example
  its description);
- the custom role **updated in place** to exactly the writer's
  permissions. It loses anything else it had, such as
  `storage.objects.setRetention` or a delete permission. Any old host
  still relying on those will fail until it's switched over.

**Stop if the plan replaces or destroys anything.**

## 4. Switch the host to the new role

The role installs its own files (`/usr/local/sbin/offsite-backup`,
`/etc/offsite-backup/backup.conf`, …) and reuses the unit names
`offsite-backup.service` and `.timer`. Set `offsite_backup_prefix` to
the prefix the host already used, so object names stay familiar.

After applying, remove anything the old implementation left that the new
one doesn't use (an old script name, an old environment file), then run
one backup by hand and a restore test before leaving it to the timer.

## 5. The old bucket

Remove the host's write access to it:

```bash
gcloud storage buckets remove-iam-policy-binding gs://<old bucket> \
  --member=serviceAccount:<account_id>@<project>.iam.gserviceaccount.com \
  --role=<old role>
```

If it has expiry rules, its objects go when their time is up. If it has
none, delete objects by hand once their retention has passed. When it's
empty, a project owner deletes the bucket.

# Upgrading from v0.1 to v0.2

v0.2 moves each retention tier into its own bucket, with the retention
set on the bucket by Terraform instead of on each object by the host
([ADR 0007](adr/0007-bucket-retention-policy-per-tier.md)). It also adds
a required size guard on the host.

**Do the Terraform and the Ansible in one sitting.** The writer role
loses `storage.objects.setRetention`, which v0.1 hosts use on every
upload. Between the Terraform apply and the Ansible apply, every v0.1
host in the project fails its backup, and its run report says so.

## What happens to existing backups

Nothing is deleted or moved. The v0.1 bucket stays as it is: every
object keeps the retention it was written with, and the bucket's expiry
rules remove each one when its tier ends. Terraform forgets the bucket
(a `removed` block in the module) rather than destroying it, and removes
the host's write access to it. Restore from it with
`scripts/restore-test --bucket <old bucket>` until it's empty, then a
project owner deletes it by hand.

**If the host ran Locked in v0.1,** its new buckets start **unlocked**.
Until you lock them (step 4), the new backups are protected from the
host but can be cleared by an operator, which is less than before. Lock
the tiers you want locked as soon as a restore test passes.

## 1. Terraform

Change the `ref` to `v0.2.0` and rename `bucket_name` to
`bucket_name_prefix`. Keeping the same value is fine: the new buckets are
`<value>-<tier>`, so they don't clash with the old bucket.

```hcl
module "host_a" {
  source             = "git::https://github.com/ledurnan/tf-gcs-backup.git//modules/backup-target?ref=v0.2.0"
  bucket_name_prefix = "yourorg-backup-host-a"   # was bucket_name
  # ... everything else unchanged
}
```

Check that `<prefix>-<longest tier name>` fits in 63 characters.

`terraform plan`, and expect exactly this for each host:

- each tier's bucket and binding (`google_storage_bucket.tier["<tier>"]`,
  `google_storage_bucket_iam_member.writer["<tier>"]`) **created**;
- the old binding (`google_storage_bucket_iam_member.writer`)
  **destroyed**, which removes the host's access to the old bucket;
- the old bucket (`google_storage_bucket.this`) **removed from state, not
  destroyed**;
- the service account unchanged, so the host's key keeps working.

And once per project:

- the writer role (`module.writer_role`) **updated in place**, losing
  `storage.objects.setRetention`.

**Stop if the plan destroys a bucket or the service account.** Apply.

## 2. Ansible

Change the collection's release URL to v0.2.0, and for each host:

```yaml
offsite_backup_bucket_name_prefix: yourorg-backup-host-a # was offsite_backup_bucket
# offsite_backup_retention_mode: removed; delete the line
offsite_backup_max_size: 2G # new and required; see below
```

The role refuses to run while `offsite_backup_retention_mode` or
`offsite_backup_bucket` is still set, and names this page.

`offsite_backup_max_size` is the largest archive the host may upload.
Take the size of a recent backup (`gcloud storage ls -l` on the old
bucket, or the host's journal) and allow a few times that.

Apply. The role checks that the key reaches each new bucket and that
each tier's retention and expiry match.

## 3. Prove it

```bash
systemctl start offsite-backup.service
scripts/restore-test --bucket-prefix yourorg-backup-host-a --prefix <host prefix> \
  --tier daily --identity operator.key --expect offsite-backup-dump/
```

## 4. Lock

Set `locked = true` on the tiers that should be locked, and apply. See
[`retention.md`](retention.md) for choosing which.

## 5. Later: remove the old bucket

Once its longest tier has expired and `gcloud storage ls` shows it
empty, a project owner deletes it. Terraform can't, by design.

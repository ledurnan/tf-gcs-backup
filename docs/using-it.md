# Using it

From nothing to a verified, locked backup for one host. Repeat steps 2 to
7 for each further host; step 1 is once per Google Cloud project.

## 1. Once per project: the write-only role

```hcl
module "writer_role" {
  source  = "git::https://github.com/ledurnan/tf-gcs-backup.git//modules/project-role?ref=v0.1.0"
  project = "your-project-id"
}
```

The role grants `storage.objects.create`, `get`, `list`,
`setRetention` and `storage.buckets.get`, and **never** a delete
permission. Every host's service account is bound to it, on that host's
bucket only.

## 2. The host's bucket and identity

```hcl
module "host_a" {
  source             = "git::https://github.com/ledurnan/tf-gcs-backup.git//modules/backup-target?ref=v0.1.0"
  project            = "your-project-id"
  location           = "europe-west2"
  bucket_name        = "yourorg-backup-host-a"
  service_account_id = "yourorg-backup-host-a"
  role_name          = module.writer_role.role_name
  tiers = [
    { name = "daily", retain_days = 7 },
    { name = "weekly", retain_days = 28 },
  ]
}
```

One bucket per host ([ADR 0001](adr/0001-one-bucket-per-host.md)). Choose
tiers with [`retention.md`](retention.md). `terraform apply`.

The bucket can't be deleted by Terraform: it has `prevent_destroy` and a
`PREVENT` deletion policy, because it will hold objects nobody can
delete.

## 3. Issue the host's key, out of band

Keys never go through Terraform, so they never reach state
([ADR 0002](adr/0002-keys-out-of-band.md)). The module's
`key_issue_command` output is the command:

```bash
gcloud iam service-accounts keys create ./yourorg-backup-host-a.json \
  --iam-account=yourorg-backup-host-a@your-project-id.iam.gserviceaccount.com \
  --project=your-project-id
```

Put the file's contents in your secret store (for example Ansible Vault)
**without opening it in an editor that wraps long lines**, then delete the
file.

## 4. The encryption keys

```bash
age-keygen -o operator.key         # prints the public key: age1...
age-keygen -o recovery.key
```

Give the host the **public** keys only. Keep the private keys off every
backed-up host: one in your password manager, one offline. Anyone with
either can read every backup; losing both loses every backup.

## 5. The sending side

Apply `ledurnan.gcs_backup.offsite_backup` to the host with the **same
tiers** (names and `retain_days`) and `lifecycle_slack_days`, a schedule
for each, and **`offsite_backup_retention_mode: Unlocked`** for now. See
[`examples/ansible/`](../examples/ansible/) and
`ansible/roles/offsite_backup/defaults/main.yml` for every variable.

The role refuses to enable with anything required missing. When it
finishes it has already proved the key reaches the bucket and that the
tier contract holds ([ADR 0003](adr/0003-tier-contract.md)).

For a database, set `offsite_backup_pre_command` to dump it into
`$DUMP_DIR`. Never list a live database's files in
`offsite_backup_paths`: the copy is torn.

## 6. Prove it

```bash
systemctl start offsite-backup.service
journalctl -u offsite-backup.service -n 30
scripts/restore-test --bucket yourorg-backup-host-a --prefix host-a \
  --tier daily --identity operator.key --expect offsite-backup-dump/
```

If you set `offsite_backup_report_url`, check the run arrived at the
heartbeat service too. Many answer `200` even to a wrong URL.

## 7. Lock it

Once a restore test passes, switch the host to
`offsite_backup_retention_mode: Locked`. From then on, nobody can delete
or shorten an object before its tier expires, including the project
owner. Objects written while Unlocked stay Unlocked.

## Then, on a schedule

Run `scripts/restore-test` regularly (with `--report-url` to alert when
it fails), and after any change to paths, the dump or the keys.

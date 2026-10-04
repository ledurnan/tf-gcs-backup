# Using it

From nothing to a verified, locked backup for one host. Repeat steps 2 to
7 for each further host; step 1 is once per Google Cloud project.

## 0. Once per project: identity and state

Start from a project that holds nothing but backups, one per system
([ADR 0010](adr/0010-backup-only-project.md)). Then run
[`scripts/bootstrap-project`](../scripts/bootstrap-project) and read
[`identity-and-state.md`](identity-and-state.md): Terraform runs as a
dedicated service account through `scripts/tf-with-identity`, never on
application-default credentials.

## 1. Once per consumer: the roles

```hcl
module "writer_role" {
  source         = "git::https://github.com/ledurnan/tf-gcs-backup.git//modules/project-role?ref=v0.2.0"
  project        = "your-project-id"
  role_id_prefix = "yourorgBackup"
}
```

This creates `yourorgBackupWriter` and `yourorgBackupEmergency`. Choose a
prefix of your own even if the project is yours alone today: if other
projects of yours share this GCP project later, each needs its own
roles, bucket names and service accounts ([ADR 0009](adr/0009-consumers-sharing-a-project.md)).

It also creates an emergency role for clearing an unlocked tier
([ADR 0008](adr/0008-emergency-access-to-unlocked-tiers.md)), unused
until step 2 names someone. The first apply waits a minute after
creating the roles, until Google accepts bindings to them.

The writer role grants `storage.objects.create`, `get` and `list`, and
`storage.buckets.get`. It **never** grants a permission to delete,
change objects or buckets, set retention, or change access. Every host's
service account is bound to it, on that host's buckets only.

## 2. The host's bucket and identity

```hcl
module "host_a" {
  source             = "git::https://github.com/ledurnan/tf-gcs-backup.git//modules/backup-target?ref=v0.2.0"
  project            = "your-project-id"
  location           = "europe-west2"
  bucket_name_prefix = "yourorg-backup-host-a"
  service_account_id = "yourorg-backup-host-a"
  role_name          = module.writer_role.role_name
  tiers = [
    { name = "daily", retain_days = 7 },
    { name = "weekly", retain_days = 28 },
  ]
}
```

One bucket per tier for each host: here `yourorg-backup-host-a-daily` and
`yourorg-backup-host-a-weekly` ([ADR 0001](adr/0001-one-bucket-per-host.md),
[ADR 0007](adr/0007-bucket-retention-policy-per-tier.md)). Each bucket's
retention policy and expiry rule come from its tier. Choose tiers with
[`retention.md`](retention.md), and leave them unlocked for now.
`terraform apply`.

Optionally, give an identity emergency access to the host's unlocked
tiers, to clear junk without the project owner's account
([`emergency.md`](emergency.md)):

```hcl
  emergency_role_name = module.writer_role.emergency_role_name
  emergency_members   = { oncall = "group:backup-emergency@yourorg.example" }
```

Use an identity kept for this alone, never on a backed-up host.

Terraform can't delete the buckets: they have `prevent_destroy` and a
`PREVENT` deletion policy, because they will hold objects nobody can
delete.

## 3. Issue the host's key, out of band

Keys never go through Terraform, so they never reach state
([ADR 0002](adr/0002-keys-out-of-band.md)).

**With Ansible Vault**, [`scripts/issue-key`](../scripts/issue-key)
issues the key and writes it straight into a vault file as one step.
The plaintext key exists only in a private directory in RAM while it
runs. Run it once without `--apply`: it checks everything and changes
nothing.

```bash
scripts/issue-key \
  --service-account yourorg-backup-host-a@your-project-id.iam.gserviceaccount.com \
  --account you@example.com \
  --vault-file inventory/host_vars/host-a/vault.yml \
  --var vault_offsite_backup_sa_key \
  --apply
```

- The vault password is found the way `ansible-vault` finds it: an
  `ansible.cfg` in the current directory, `ANSIBLE_VAULT_PASSWORD_FILE`,
  or `--vault-password-file` / `--vault-id`.
- It refuses to overwrite a key that's already there. `--rotate` replaces
  it and prints the commands to delete the old key once the host has the
  new one.
- If any step after issuing fails, or it is interrupted, it puts the
  vault back and deletes the new key in Google Cloud. If even that
  fails, it exits 3 and prints what to delete by hand.
- `--help` lists every option: the project, a new vault file, the work
  directory and how ansible-vault is called.

**With another secret store**, the module's `key_issue_command` output is
the command:

```bash
gcloud iam service-accounts keys create ./yourorg-backup-host-a-sa.json \
  --iam-account=yourorg-backup-host-a@your-project-id.iam.gserviceaccount.com \
  --project=your-project-id
```

Put the file's contents in your secret store **without opening it in an
editor that wraps long lines**, then delete the file. Until then it is a
live credential sitting in your working directory: add `*-sa.json` to
your repository's `.gitignore` so it can't be committed by accident.

## 4. The encryption keys

Every host encrypts to two age keys: an everyday **operator** key, kept
in your password manager, and a **recovery** key, kept offline. Issue
each with [`scripts/issue-age-key`](../scripts/issue-age-key), in your
own terminal:

```bash
scripts/issue-age-key --name operator --retain-days 365
scripts/issue-age-key --name recovery --retain-days 365
```

It shows the private key once, on a screen that is cleared afterwards,
then asks you to paste it back from where you saved it. Only when that
matches is the key issued, and only then does it print the public key
(`age1...`). Nothing is written to disk. If it fails or is interrupted
first, the key is not issued: don't use its public key.

It runs itself in a systemd scope that may not swap, and refuses to run
if it can't ([swap guard](swap-guard.md)). Check a machine first with
`scripts/issue-age-key --check-guard`.

Give the hosts the **public** keys only, in
`offsite_backup_age_recipients`. Keep the private keys off every
backed-up host. Anyone with either can read every backup; losing both
loses every backup.

When you replace a key, keep the old private key until the last backup
encrypted to it has expired: the longest `retain_days` plus
`lifecycle_slack_days` after the hosts stop using it. `--retain-days`
makes it print that date.

## 5. The sending side

Apply `ledurnan.gcs_backup.offsite_backup` to the host with
`offsite_backup_bucket_name_prefix` from the module's output, the **same
tiers** (names and `retain_days`) and `lifecycle_slack_days`, and a
schedule for each tier. See
[`examples/ansible/`](../examples/ansible/) and
`ansible/roles/offsite_backup/defaults/main.yml` for every variable.

The role refuses to enable with anything required missing. When it
finishes it has already proved the key reaches each tier's bucket and
that the tier contract holds ([ADR 0003](adr/0003-tier-contract.md)).

For a database, set `offsite_backup_pre_command` to dump it into
`$DUMP_DIR`. Never list a live database's files in
`offsite_backup_paths`: the copy is torn.

Set `offsite_backup_max_size` from a measured archive with headroom.
Each run's archive is stored once per due tier, so this is also where
you decide the order of magnitude this host costs to keep. A run over
the ceiling, or one that grew more than `offsite_backup_max_growth_percent`
since the last good run, fails before uploading anything and reports
why. If the growth is expected, `touch /var/lib/offsite-backup/accept-size`
and run the backup again: the growth check is skipped once.

What can and can't be selected (no excludes, one archive and schedule
per host) is in [limitations](limitations.md).

## 6. Prove it

```bash
systemctl start offsite-backup.service
journalctl -u offsite-backup.service -n 30
scripts/restore-test --bucket-prefix yourorg-backup-host-a --prefix host-a \
  --tier daily --identity operator.key --expect offsite-backup-dump/
```

If the timer has already run today, the manual run keeps the copy that
run stored ("already stored today") rather than writing a second one.
Each tier is tried even when another fails, so running it again after a
part-failed run writes only what's missing.

If you set `offsite_backup_report_url`, check the run arrived at the
heartbeat service too. Many answer `200` even to a wrong URL.

## 7. Lock it

Once a restore test passes, set `locked = true` on the tiers you want
locked, in Terraform, and apply. From then on, nobody can delete an
object in those buckets before it is `retain_days` old, or shorten the
policy, including the project owner. The lock applies to every object in
the bucket, including those already there. Nothing changes on the host.

Whether to lock a short tier is a choice. Unlocked, an operator can clear
a mistake or a compromised host's junk. Locked, nobody can. See
[`retention.md`](retention.md).

## Then, on a schedule

Run `scripts/restore-test` regularly (with `--max-age` and
`--report-url-file` to alert when it fails or backups stop), and after
any change to paths, the dump or the keys. See
[`restore.md`](restore.md#proving-it-before-you-need-it).

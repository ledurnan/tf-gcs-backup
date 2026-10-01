# tf-gcs-backup

Off-site backups to Google Cloud Storage that a compromised host can't
erase. Each host writes encrypted archives to its own bucket with a
credential that can add objects but **never delete them**, and every
object is protected by per-object retention until its tier expires.

Two halves, versioned together:

|                    | What                                                                  | Where                                                            |
| ------------------ | --------------------------------------------------------------------- | ---------------------------------------------------------------- |
| **Receiving side** | Bucket, retention tiers, write-only role, service account             | Terraform: [`modules/`](modules/)                                |
| **Sending side**   | Dump step, archive, `age` encryption, upload, schedule, run reporting | Ansible collection `ledurnan.gcs_backup`: [`ansible/`](ansible/) |

It holds no state, no secrets and no real project IDs. Each project that
uses it calls the modules and the role at a pinned tag, with its own
values, credentials and Terraform state.

## Use it

```hcl
module "writer_role" {
  source  = "git::https://github.com/ledurnan/tf-gcs-backup.git//modules/project-role?ref=v0.1.0"
  project = "your-project-id"
}

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

```yaml
# requirements.yml
collections:
  - name: https://github.com/ledurnan/tf-gcs-backup/releases/download/v0.1.0/ledurnan-gcs_backup-0.1.0.tar.gz
    type: url
```

Install from the release file, not from git. A git-sourced collection is
cloned by `ansible-galaxy`, and inside a git hook (an ansible-lint
pre-commit hook installs `requirements.yml`) that clone inherits
`GIT_INDEX_FILE` and overwrites the committing repository's index.

Then apply `ledurnan.gcs_backup.offsite_backup` to the host with the
same tiers. [`docs/using-it.md`](docs/using-it.md) walks through the
whole thing, and [`examples/`](examples/) has a configuration host and a
database host side by side.

## Before you choose retention

Retention is a data-protection decision, and **locked retention can't be
shortened once an object is written**. Read
[`docs/retention.md`](docs/retention.md) before setting tiers for a host
that holds personal data.

## Restoring

[`docs/restore.md`](docs/restore.md). Prove it works on a schedule with
[`scripts/restore-test`](scripts/restore-test): a backup nobody has
restored is a rumour.

## Scope

v0.1 supports Debian and Ubuntu hosts with systemd. Not covered: other
clouds, VM or disk images, and deduplicating or incremental backup. This
pattern writes a full copy per tier, trading storage efficiency for a
host that can't delete its own backups. Everything else it doesn't
do is in [`docs/limitations.md`](docs/limitations.md).

What it protects against, and what it doesn't yet, is in
[`docs/threat-model.md`](docs/threat-model.md). Decisions are recorded in
[`docs/adr/`](docs/adr/README.md).

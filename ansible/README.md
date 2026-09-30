# ledurnan.gcs_backup

The sending side of [tf-gcs-backup](../README.md): the `offsite_backup`
role installs the backup script, its systemd timer and the run-report
hook on a host. The receiving side (bucket, write-only role, service
account) is the Terraform in `../modules/`.

Install the file attached to a release:

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

Use as `ledurnan.gcs_backup.offsite_backup`. Variables are documented in
`roles/offsite_backup/defaults/main.yml`.

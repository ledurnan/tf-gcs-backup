# ledurnan.gcs_backup

The sending side of [tf-gcs-backup](../README.md): the `offsite_backup`
role installs the backup script, its systemd timer and the run-report
hook on a host. The receiving side (bucket, write-only role, service
account) is the Terraform in `../modules/`.

Install from a tag:

```bash
ansible-galaxy collection install \
  "git+https://github.com/ledurnan/tf-gcs-backup.git#/ansible/,v0.1.0"
```

Use as `ledurnan.gcs_backup.offsite_backup`. Variables are documented in
`roles/offsite_backup/defaults/main.yml`.

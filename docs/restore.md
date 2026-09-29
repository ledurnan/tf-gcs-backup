# Restoring

You need:

- a Google identity that can read the bucket (an operator's, not the
  host's: the host's key can read its own objects back but should stay on
  the host);
- an `age` private key matching one of the host's recipients. **Without
  it the backups can't be read.** Nothing about GCS durability changes
  that.

## 1. Find the object

```bash
gcloud storage ls gs://<bucket>/<tier>/<prefix>/
```

Object names are dated within each tier (`daily/<prefix>/2026-06-03.tar.age`,
`weekly/<prefix>/2026-W23.tar.age`, `monthly/<prefix>/2026-06.tar.age` by
default), so the last one listed is the newest.

## 2. Fetch and decrypt, into a scratch directory

```bash
mkdir -p restore
gcloud storage cp gs://<bucket>/daily/<prefix>/2026-06-03.tar.age .
age -d -i operator.key 2026-06-03.tar.age | tar -xz -C ./restore
```

Never unpack straight over a live system.

The archive holds each configured path relative to `/` (for example
`restore/etc/letsencrypt/`), plus `restore/offsite-backup-dump/` with
whatever the pre-backup command wrote (for example a database dump).

## 3. Put back only what you need

In a rebuild, reinstall the host and re-apply your configuration
management first. Then restore only what it can't recreate: the database
from its dump (with your database's own restore tool), and the files the
application keeps.

## Proving it before you need it

```bash
scripts/restore-test --bucket <bucket> --prefix <prefix> --tier daily \
  --identity operator.key \
  --expect offsite-backup-dump/ --expect etc/letsencrypt/ \
  --report-url https://heartbeat.example/<id>
```

It fetches the newest object, decrypts it, lists it, checks each
`--expect` entry is present, and reports the result to the URL. It
extracts nothing. Schedule it where an operator key is available (never
on the backed-up host), and run it after any change to paths, the dump or
the keys.

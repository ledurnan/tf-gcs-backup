# Restoring

You need:

- a Google identity that can read the bucket (an operator's, not the
  host's: the host's key can read its own objects back but should stay on
  the host);
- an `age` private key matching one of the host's recipients. **Without
  it the backups can't be read.** Nothing about GCS durability changes
  that.

## 1. Find the object

Each tier is its own bucket, `<bucket name prefix>-<tier>`:

```bash
gcloud storage ls gs://<bucket name prefix>-<tier>/<prefix>/
```

Object names are dated (`<prefix>/2026-06-03.tar.age` daily,
`<prefix>/2026-W23.tar.age` weekly, `<prefix>/2026-06.tar.age` monthly,
by default), so the last one listed is the newest.

Backups written by v0.1 are in a single bucket, under
`gs://<bucket>/<tier>/<prefix>/`, until they expire.

## 2. Fetch and decrypt, into a scratch directory

```bash
mkdir -p restore
gcloud storage cp gs://<bucket name prefix>-daily/<prefix>/2026-06-03.tar.age .
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
scripts/restore-test --bucket-prefix <bucket name prefix> --prefix <prefix> --tier daily \
  --identity operator.key \
  --expect offsite-backup-dump/ --expect etc/letsencrypt/ \
  --report-url https://heartbeat.example/<id>
```

It fetches the newest object, decrypts it, lists it, checks each
`--expect` entry is present, and reports the result to the URL. For a
v0.1 bucket, pass `--bucket <bucket>` instead of `--bucket-prefix`. It
extracts nothing. Schedule it where an operator key is available (never
on the backed-up host), and run it after any change to paths, the dump or
the keys.

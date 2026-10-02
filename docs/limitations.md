# Limitations

What it doesn't do, so you can check a host fits before adopting it.

## What gets backed up

- **No excludes.** Each entry in `offsite_backup_paths` is archived whole
  and recursively. To leave something out, list the subdirectories you
  want, or copy the subset into `$DUMP_DIR` from the pre-backup command.
  Tracked in [#14](https://github.com/ledurnan/tf-gcs-backup/issues/14).
- **No globs.** Paths are literal absolute paths. A path that doesn't
  exist when the backup runs makes tar fail, and nothing is uploaded.
- **No per-path settings.** All paths and the dump go into one archive
  with the same tiers, recipients and schedule.

## Schedule and retention

- **One archive per host, one schedule.** A host has one config, one
  systemd timer and one prefix. You can't back up a database hourly and
  a config directory weekly on the same host.
- **Same tiers for everything on a host.** Each due tier gets the same
  archive. Data that needs a different retention period needs its own
  host and bucket.
- **Tier triggers are coarse.** `when` is `always`, one weekday or one
  day of the month (01 to 28). There's no "last day of the month", no
  "every N days" and no list of days.
- **One object per name.** A stored object can't be overwritten, so a
  tier keeps one copy per name. With the default names that is one per
  day, week or month. A second run on the same day keeps the copy already
  stored and says so. To keep every run, add the time to the tier's
  `name_format` (for example `%Y-%m-%dT%H%M%SZ`). A `name_format` must
  give a new name on every day its tier is due: a name stored on an
  earlier day fails the run.

## Storage

- **Full copies only.** No incremental or deduplicated backup. Every
  tier stores a complete copy, so storage grows with
  (data size × objects kept per tier).
- **Built locally first.** The encrypted archive is written to
  `offsite_backup_work_dir` before upload, so the host needs free space
  for one compressed, encrypted copy.
- **No VM or disk images.** It backs up files and whatever the
  pre-backup command writes.

## Platform

- Debian and Ubuntu hosts with systemd only. The role installs with apt.
- Google Cloud Storage only.

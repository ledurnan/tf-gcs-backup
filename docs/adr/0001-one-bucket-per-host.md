# 0001: One bucket per backed-up host

- Status: Proposed

## Context

A compromised host must reach only its own backups. Each host has its own
service account, bound to a write-only role that includes
`storage.objects.list` and `storage.objects.get` (to verify its uploads)
and `storage.buckets.get` (for the tier contract). If several hosts share
a bucket, those permissions let each one list and fetch the others'
objects, and set retention on them.

Options considered:

- **One bucket per host.** The binding is on the bucket, so isolation is
  structural. Buckets cost nothing to exist. Each bucket's lifecycle rules
  then match exactly one host's tiers, so two hosts in one project can
  have different retention.
- **A shared bucket with per-host managed folders.** Managed folders take
  their own IAM, but they add a second mechanism to reason about, and
  listing and bucket-level reads still need checking against how GCS
  evaluates them. Lifecycle rules stay per bucket, so hosts sharing it
  would share retention.
- **A shared bucket with IAM conditions on the object prefix.** Conditions
  apply to object reads and writes, but listing is checked at bucket
  level, so hosts would still see each other's object names.

## Decision

One bucket per host. The `backup-target` module creates a bucket, a
service account and a bucket-level binding together, so it can't be used
any other way.

## Consequences

- More buckets, each with a globally unique name: choose a distinctive
  prefix.
- Per-host retention comes free, which matters when one host holds
  personal data under a short retention promise and another doesn't.
- An existing shared bucket (from before this pattern) stays shared until
  its hosts are moved to buckets of their own.

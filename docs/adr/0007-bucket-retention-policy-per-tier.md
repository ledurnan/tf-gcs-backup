# 0007: Retention is a bucket policy, one bucket per tier

- Status: Proposed
- Amends [0001](0001-one-bucket-per-host.md) (one bucket per host
  becomes one bucket per host per tier) and
  [0003](0003-tier-contract.md) (the tier contract checks retention as
  well as expiry).

## Context

In v0.1 every tier shared one bucket, as a prefix (`daily/`, `weekly/`,
…). Each object's retention was set at upload by the host: the writer
role held `storage.objects.setRetention`, and the host passed
`--retain-until` and `--retention-mode` on every upload.

That left the decision about how long data is kept with the party the
design assumes will be compromised ([threat model](../threat-model.md)):

- **T3:** expiry rules matched tier prefixes, so an object written
  anywhere else never expired.
- **T4:** the host chose each object's retain-until and mode. A
  compromised host could write objects Locked for as long as it liked,
  and nobody, including the project owner, could remove them.
- **T5:** together, storage charges with no upper limit that nobody
  could reduce: denial of wallet.

Locked mode was also all or nothing for a host. It could not be Locked
for long tiers and recoverable for short ones.

Options considered:

- **Restrict the writer with IAM conditions** (create only under tier
  prefixes). Doesn't stop it choosing retention, which is the worst
  case, and conditions on object names are easy to get subtly wrong.
- **A catch-all expiry rule** for objects outside the tier prefixes.
  Closes T3 only.
- **A bucket retention policy, one bucket per tier.** Retention is set by
  Terraform on the bucket. The host needs no retention permission, and
  per-object retention can stay off, so it can't choose any.

## Decision

Each tier gets its own bucket, `<bucket_name_prefix>-<tier>`, with:

- a **bucket retention policy** of `retain_days`, locked only when that
  tier sets `locked = true`;
- **one expiry rule with no prefix**, at `retain_days + slack`, so every
  object in the bucket expires whatever its name;
- **per-object retention off** (`enable_object_retention = false`).

The writer role loses `storage.objects.setRetention`. Its permissions
are now exactly `storage.objects.create`, `get`, `list` and
`storage.buckets.get`, and a precondition refuses any permission that
deletes, updates, sets retention or IAM, or overrides retention.

The host no longer has a retention setting:
`offsite_backup_retention_mode` is removed, and the role refuses to run
if it's still set. The tier contract checks each tier's bucket for both
its retention period and an expiry rule covering every object.

## Consequences

- **The host can't decide how long anything is kept.** Junk it writes
  lives at most its tier's retention plus slack, then expires. That
  closes T3 and T4. T5 now has an upper limit: upload rate × the
  retention of the tiers the host can write to.
- **Locking is per tier, in Terraform.** A short tier can stay unlocked,
  so an operator can remove a mistake by shortening or removing its
  policy. A long tier can be locked against an attacker with cloud
  admin access.
- **The host still writes every tier.** A locked long tier is still
  exposed to junk for its whole retention. Removing the host's access to
  long tiers needs a trusted promotion job (threat model C22). That's a
  separate decision.
- **More buckets:** one per host per tier, each with a globally unique
  name. Bucket names are at most 63 characters, so the prefix and tier
  name together must fit.
- **Bucket retention locks the whole bucket.** An unlocked policy can be
  shortened or removed by anyone with `storage.buckets.update`, which
  includes the Terraform identity (T12). Lock long tiers, and watch for
  changes to bucket configuration (C27).
- **Upgrading from v0.1** creates new buckets. The old bucket is
  forgotten by Terraform, not destroyed, and ages out under its own
  rules ([`upgrading-to-v0.2.md`](../upgrading-to-v0.2.md)). Hosts must
  be moved to v0.2 straight after the Terraform apply: the writer role
  loses `setRetention`, so v0.1 uploads fail until then.
- **Behaviour still to confirm on real GCS** (see #7): that an unlocked
  policy can be removed and its objects deleted by an operator, that a
  writer without `setRetention` can't set object retention, how
  `gcloud storage buckets describe` reports the policy, and whether a
  locked policy blocks deleting the project.

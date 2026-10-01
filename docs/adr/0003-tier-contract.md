# 0003: The host checks the bucket's expiry rules before every run

- Status: Proposed. Amended by [0007](0007-bucket-retention-policy-per-tier.md):
  each tier is its own bucket, and the check covers its retention policy
  as well as its expiry rule. The decision to check on the host is
  unchanged.

## Context

Retention lives in two places. The bucket's lifecycle rules (Terraform)
delete `<tier>/` objects after `retain_days + slack`; the host (Ansible)
writes each object with a retain-until of `retain_days`. If they
disagree, objects are either deleted sooner than the host thinks (the
lifecycle rule fails against retention, and they linger) or kept longer
than the consumer promised. In the implementation this came from, the
only safeguard was a comment saying the two lists must match.

Options considered:

- **Pass the module's `tiers` output into the role's variables.** Removes
  retyping when both live in one repository, but enforces nothing, and
  often they don't.
- **A shared schema file both halves read.** Can't span a Terraform state
  in one repository and an inventory in another.
- **The host reads the bucket's lifecycle rules and compares.** Enforced
  where it matters, before anything is written, whatever repositories the
  two halves live in.

## Decision

The host checks. The write-only role includes `storage.buckets.get`, and
`offsite-backup` reads the bucket's lifecycle rules at the start of every
run, refusing to upload unless each of its tiers has a Delete rule for
`<tier>/` at exactly `retain_days + slack`. The role runs the same check
(`offsite-backup --check-contract`) when it's applied. The module also
outputs `tiers` so the values can be copied rather than retyped.

Since [0007](0007-bucket-retention-policy-per-tier.md), the check reads
each tier's bucket (`<bucket_name_prefix>-<tier>`) and requires a
retention policy of exactly `retain_days` and a Delete rule with no
prefix at exactly `retain_days + slack`. It reports every tier that
disagrees, not just the first, and logs whether each tier is locked.

## Consequences

- A mismatch fails loudly, at deploy time and on every run, with the
  tier and the two numbers named.
- `storage.buckets.get` lets the host read its bucket's configuration.
  It doesn't grant reading or changing the bucket's IAM policy.
- Changing tiers is ordered: Terraform first, then Ansible. In between,
  the host refuses to upload.

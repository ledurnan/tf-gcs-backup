# 0008: Emergency access to unlocked tiers

- Status: Proposed

## Context

[ADR 0007](0007-bucket-retention-policy-per-tier.md) made retention a
bucket policy, locked or unlocked per tier. A compromised host, or a
mistake that slips past the size guard, can fill a tier with data that
shouldn't be kept and that costs money to keep
([threat model](../threat-model.md) T5, T24). In an unlocked tier that
can be undone: remove the bucket's retention policy, delete the objects,
and put the policy back.

Until now the only identity that could do that was the project owner,
whose account is used for everything else, or the Terraform identity,
which can remove a policy but not delete objects (it could grant itself
that, which is threat T12, not a route to rely on).

## Decision

`project-role` creates a second custom role, **`offsiteBackupEmergency`**,
with exactly:

- `storage.buckets.get` and `storage.buckets.update`, to see and remove
  or shorten an unlocked tier's retention policy;
- `storage.objects.list`, `storage.objects.get` and
  `storage.objects.delete`. `gcloud` reads an object's metadata before
  deleting it, so `get` is needed. It also allows downloading, but every
  object is age-encrypted and unreadable without the operators' private
  keys.

It can't add objects, set object retention, or read or change access. A
precondition refuses any of those.

`backup-target` takes an optional `emergency_members` map (a name you
choose → `user:`, `group:` or `serviceAccount:` principal) and binds each
on the host's **unlocked tiers only**. A locked tier's policy can't be
removed by anyone, so access there would only widen exposure. It's empty
by default. The host's own writer can never be a member.

The steps for using it are in [`docs/emergency.md`](../emergency.md).

## Consequences

- An emergency principal **can empty an unlocked tier.** That's the point,
  and it's also its risk (T11). Use an identity kept for this alone:
  never on a backed-up host, not anyone's everyday account, with strong
  authentication. A group whose membership is changed only in an
  emergency keeps standing access at zero.
- `storage.buckets.update` also allows other bucket changes: the expiry
  rule, labels, or **locking** the policy (which can't be undone).
  Terraform reports any of these as drift on the next plan, and
  `terraform apply` puts back everything except a lock.
- While a tier's policy is removed, the host's tier contract fails and
  its backups stop with an alert. That's the intended signal: put the
  policy back with `terraform apply` as soon as the clean-up is done.
- Locked tiers have no emergency route, by design. Junk written to a
  locked tier stays for its full retention. Keeping the host out of long
  tiers altogether is a separate control (threat model C22).
- `project-role` waits (`role_propagation_seconds`, default 60) after
  creating or renaming a role before anything binds it. Without the wait,
  the first apply failed with "does not exist in the resource's
  hierarchy" against real Google Cloud. This adds the `hashicorp/time`
  provider.

# 0010: Keep backups in a project that holds nothing else

- Status: Proposed

## Context

Every bucket this pattern creates sits in one Google Cloud project, and
Google Cloud grants most IAM roles at project level. A project that also
runs services collects broad grants over time: a CI deploy service
account, an application's runtime service account, `roles/editor` for a
colleague or a console wizard. Most of those roles include
`storage.buckets.delete` and `storage.objects.delete` on every bucket in
the project, backups included, and none of them shows up in this
repository's Terraform.

Who can delete matters most on an **unlocked** tier. A locked tier
survives anyone ([ADR 0007](0007-bucket-retention-policy-per-tier.md)),
but there are good reasons to leave tiers unlocked: data that must be
erasable on request, and junk a stolen writer key uploads that should be
clearable ([threat model](../threat-model.md) T5, T26). There, the set of
identities that can delete is the main control.

A project ID can't be changed after creation; only its display name can.

## Decision

**Put backups in a Google Cloud project that holds nothing but backups,
one per system** (the hosts that serve one service and share its age
keys). Any other cloud service that system needs goes in a separate
project.

In such a project, the identities that can remove a backup are:

- the project owners;
- the emergency principal, if any, on unlocked tiers only
  ([ADR 0008](0008-emergency-access-to-unlocked-tiers.md));
- the Terraform identity, which can't delete but can grant or change
  retention ([threat model](../threat-model.md) T12).

Host writer keys can't delete anything. Nothing else is granted in the
project, so nothing else can.

Name the project for what it holds, for example `<org>-<system>-backup`,
because the ID is permanent.

A separate project costs nothing extra in Google Cloud: billing account,
budgets and organisation policies are shared. It does use one of the
billing account's project slots. Where those run out, several systems'
backups may share one backup-only project, each with its own names
([ADR 0009](0009-consumers-sharing-a-project.md)); they still share
nothing with non-backup services.

Rejected:

- **One general project per system, backups included.** Simpler to set
  up, but every future service identity in it can reach the unlocked
  buckets.
- **A general project, with care over who is granted what.** The control
  is a habit, not a boundary, and grants made elsewhere (a console
  wizard, another team's Terraform) don't pass through this repository.

## Consequences

- `scripts/bootstrap-project` is run for a new, empty project per
  system. A grant in that project for any other purpose breaks the rule.
- Google enables some APIs on every new project (BigQuery, logging and
  others). They grant nothing, so they don't break the rule.
- A system that later needs other cloud services needs a second project,
  with its own identity and state.
- Moving backups from a mixed project into a backup-only one means new
  buckets (bucket names are global and the old ones keep theirs), new
  writer keys, and letting the old buckets expire before a project owner
  deletes them.

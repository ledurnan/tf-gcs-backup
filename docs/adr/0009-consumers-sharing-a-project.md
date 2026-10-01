# 0009: Consumers sharing a project name everything their own

- Status: Accepted

## Context

A Google Cloud billing account can only have a few projects linked, so
unrelated projects of one owner (a mail service, an FOI app) may keep
their backups in one shared Google Cloud project. Each of those
consumers runs its own Terraform, with its own state, and none knows
about the others.

Three names a consumer creates must be unique:

- **Bucket names**, across all of Google Cloud. A clash fails at
  create, so it's found at once.
- **Service account IDs**, within the project. Two consumers choosing
  the same ID would share one identity, and so one set of backups.
- **Custom role IDs**, within the project. Until v0.2 every consumer's
  `project-role` created `offsiteBackupWriter`. The second consumer
  either fails on create or, once it adopts the role, keeps setting it
  back to its own version. A role change between versions breaks hosts
  still on the old version: v0.2 removes `setRetention`, which v0.1
  hosts need. One consumer's upgrade would break the other's backups,
  from a different repository.

Options considered:

- **One owner of the roles per project:** a separate configuration
  creates them and every consumer refers to them by name. Every consumer
  in the project then has to upgrade at the same moment as the roles.
- **Each consumer names its own roles.** No coordination, and each
  upgrades on its own schedule. It costs more roles, and a project allows
  hundreds.

## Decision

Each consumer names its own roles. `project-role` has no default role
IDs: it requires `role_id_prefix`, and creates `<prefix>Writer` and
`<prefix>Emergency`.

By convention, a consumer starts all three names with the same short
name for itself:

| Name                   | Example (the mail relay)                                  |
| ---------------------- | --------------------------------------------------------- |
| Roles                  | `sendhopBackupWriter`, `sendhopBackupEmergency`           |
| Bucket prefix          | `sendhop-offsite-backup` → `sendhop-offsite-backup-daily` |
| Writer service account | `sendhop-offsite-backup`                                  |

Use the same convention in a project that only one consumer uses: it
costs nothing, and the project can then be shared later without
renaming anything.

## Consequences

- One consumer's Terraform can't change another's roles, buckets or
  service accounts, and consumers upgrade independently.
- A consumer upgrading from v0.1 had the default role ID. Picking a new
  prefix means a new role. The Terraform identity can't delete roles, so
  the upgrade forgets the old one first and a project owner deletes it
  by hand afterwards ([`upgrading-to-v0.2.md`](../upgrading-to-v0.2.md)).
- Nothing stops a consumer reusing another's prefix deliberately or by
  mistake. The convention is the control, and the names in each
  consumer's Terraform are where to check it.

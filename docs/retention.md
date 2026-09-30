# Choosing retention

Every object is written with a retain-until of `retain_days` from its
upload, and the bucket deletes it `retain_days + lifecycle_slack_days`
after upload. Both halves must use the same tiers
([ADR 0003](adr/0003-tier-contract.md)).

## Locked is irreversible

| Mode       | Before retain-until                                                            | Use for                                    |
| ---------- | ------------------------------------------------------------------------------ | ------------------------------------------ |
| `Unlocked` | An operator with the right permission can remove or shorten it                 | First rollout, testing                     |
| `Locked`   | **Nobody** can delete it or shorten its retention, including the project owner | Production, once a restore test has passed |

A locked object uploaded by mistake, containing the wrong data or too
much of it, stays for its full tier. There is no support ticket that
removes it.

## Personal data

If a host holds personal data, the longest tier is how long that data
survives in backups, including data a person has since had erased from
the live system. Check what the service has promised (privacy notice,
retention schedule, contracts) and set tiers inside it, counting the
slack day. For example, a promise of "backups kept for 35 days or less"
allows `weekly` at 28 days (plus 1 day of slack), not a monthly tier.

`location` is also yours to choose, and can matter for the same reason.

## Cost

Each due tier stores a full copy. A host with 2 GB of backup data and
daily (7 days), weekly (28 days) and monthly (365 days) tiers holds
roughly 7 + 4 + 12 = 23 copies at steady state, about 46 GB. Small data
makes long history free; large data makes it the main cost.

Cold storage classes (`NEARLINE` 30 days, `COLDLINE` 90, `ARCHIVE` 365)
bill early deletion, so the module refuses them when any tier is shorter
than the class minimum. `STANDARD` has no minimum.

Soft delete, if enabled on the bucket, keeps expired objects (and bills
for them) for its own window after the lifecycle rule deletes them. The
module leaves it alone unless you set `soft_delete_retention_seconds`.

## Changing tiers later

- **Adding a tier** or **lengthening one**: change both halves. Existing
  objects keep the retention they were written with.
- **Shortening a tier**: new objects follow the new length. Locked objects
  already written keep their original retain-until. The lifecycle rule
  tries to delete them sooner, fails while retention holds, and removes
  them once it expires.
- **Removing a tier**: its objects are no longer expired by a rule. Keep
  the rule until the last locked object has expired, then remove it.

Change the Terraform first and apply, then the Ansible. In between, the
host refuses to upload, because the contract no longer holds. That's the
check doing its job.

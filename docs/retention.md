# Choosing retention

Each tier is its own bucket, `<bucket_name_prefix>-<tier>`. Its
retention policy keeps every object for `retain_days`, and its expiry
rule deletes every object `retain_days + lifecycle_slack_days` after
upload. Both are set in Terraform. The host never chooses retention
([ADR 0007](adr/0007-bucket-retention-policy-per-tier.md)), and it checks
before every run that its tiers match the buckets
([ADR 0003](adr/0003-tier-contract.md)).

## Locked is irreversible

Locking is set per tier, with `locked` in the module's `tiers`:

| `locked`          | Before an object is `retain_days` old                                                                                                                                                                    | Use for                                                              |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `false` (default) | Nobody can delete it. An operator with `storage.buckets.update` (an emergency member, or the owner) can shorten or remove the bucket's policy, and then delete objects ([`emergency.md`](emergency.md)). | First rollout, testing, and short tiers you want to be able to clear |
| `true`            | **Nobody** can delete it or shorten the policy, including the project owner. The period can only be lengthened.                                                                                          | Long tiers, once a restore test has passed                           |

Locking happens when Terraform applies `locked = true`, and can't be
undone. Afterwards, a plan that shortens `retain_days` fails at apply,
because GCS refuses. A plan that sets `locked` back to `false` asks to
**replace the bucket**, and the module's `prevent_destroy` stops it before
anything is sent to Google. Deletion protection on the bucket and the
lock itself would refuse it too.

A locked tier keeps everything in it for its full retention. That
includes a mistaken upload and, because the host can still write every
tier, junk from a compromised host. The size guard
(`offsite_backup_max_size`) catches the first. The
[threat model](threat-model.md) covers the second (T5, C22).

## Personal data

If a host holds personal data, its longest tier is how long that data
survives in backups, including data a person has since had erased from
the live system. Check what the service has promised (privacy notice,
retention schedule, contracts) and set tiers inside it, counting the
slack day. For example, a promise of "backups kept for 35 days or less"
allows `weekly` at 28 days (plus 1 day of slack), but not a monthly tier.

`location` is also yours to choose, and can matter for the same reason.

## Cost

Each due tier stores a full copy. A host with 2 GB of backup data and
daily (7 days), weekly (28 days) and monthly (365 days) tiers holds
roughly 7 + 4 + 12 = 23 copies at steady state, about 46 GB. Small data
makes long history free. With large data, retention is the main cost.

`offsite_backup_max_size` multiplied by the copies each tier holds is
the most a host can store if it is working as intended.

Cold storage classes (`NEARLINE` 30 days, `COLDLINE` 90, `ARCHIVE` 365)
bill early deletion, so the module refuses them when any tier is shorter
than the class minimum. `STANDARD` has no minimum.

Soft delete, if enabled on a bucket, keeps expired objects (and bills
for them) for its own window after the expiry rule deletes them. New
buckets get Google's default (7 days at the time of writing), which
nearly doubles what a 7-day tier holds. The module leaves soft delete
alone unless you set `soft_delete_retention_seconds`.

## Changing tiers later

Change the Terraform first and apply, then the Ansible. In between, the
host refuses to upload because the contract no longer holds. That's the
check doing its job.

- **Adding a tier:** a new bucket. Add it to both halves.
- **Lengthening a tier:** the bucket's policy grows. It applies to
  objects already there as well as new ones.
- **Shortening an unlocked tier:** the policy shrinks, and that applies
  to objects already there. Objects already past the new period become
  deletable straight away, and the expiry rule removes them.
- **Shortening a locked tier:** not possible. Add a new, shorter tier,
  move the host to it, and let the old one run out (as below).
- **Removing a tier:** the bucket can't be destroyed by Terraform, so a
  plan that drops it fails. Take the tier out of the host's Ansible
  first. Then, in Terraform, remove it from `tiers` and add a `removed`
  block for its bucket and binding (`lifecycle { destroy = false }`),
  so Terraform forgets them. Its objects expire under its own rules.
  Once it's empty, a project owner deletes the bucket by hand.

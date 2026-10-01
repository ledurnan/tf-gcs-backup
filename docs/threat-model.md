# Threat model

What can go wrong with a backup made this way, and what in this
repository deals with it. Threats are numbered `T`, controls `C`. Each
control lists the threats it addresses, and the
[coverage table](#coverage) works back from each threat to its controls
and what's left over.

Statuses:

- **In place**: in the latest release.
- **Unreleased**: on `main`, not yet tagged.
- **Proposed**: designed, not built. See the linked issue.
- **Consumer**: outside this repository; each project that uses it must
  do it.

## Scope and assumptions

**What's protected:** the backup objects (their existence, integrity
and confidentiality), the ability to restore from them, and the bill.

**Actors:**

| Actor              | Holds                                                     | Trusted?                                                                             |
| ------------------ | --------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Backed-up host     | The writer service account key, the live data             | **No.** The design assumes it will be compromised at some point.                     |
| Operator           | An identity that can impersonate the Terraform account    | Yes, but its compromise is a threat (T11).                                           |
| Terraform identity | Manage buckets, roles and service accounts in the project | Partly. It's limited by `scripts/bootstrap-project`, and it's still powerful (T12).  |
| Age key holders    | The private keys that decrypt backups                     | Yes. The keys never touch the host.                                                  |
| Google Cloud       | The objects, at rest                                      | For availability, yes. For confidentiality, no: objects are encrypted before upload. |

**Out of scope:** the security of the live system itself, the
correctness of the consumer's dump (beyond checks in the
[pre-backup hook](using-it.md#5-the-sending-side)), and attacks on Google
Cloud's own infrastructure.

## Threats

### From a compromised host, or a stolen writer key

| ID  | Threat                                                                                                                                                     |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| T1  | Deletes or overwrites its existing backups (ransomware that destroys backups before encrypting live data).                                                 |
| T2  | Shortens or removes the retention on existing backups so they can then be deleted or expire early.                                                         |
| T3  | Writes objects that never expire: outside every tier prefix, so no lifecycle rule matches them ([#7](https://github.com/ledurnan/tf-gcs-backup/issues/7)). |
| T4  | Writes objects with a retention far beyond its tier, Locked, so nobody can remove them ([#7](https://github.com/ledurnan/tf-gcs-backup/issues/7)).         |
| T5  | **Denial of wallet by volume**: uploads large or many objects, which are stored and billed until they expire.                                              |
| T6  | **Denial of wallet by requests**: floods the API with tiny writes, billed per operation whatever their retention.                                          |
| T7  | Reads or tampers with another host's backups.                                                                                                              |
| T8  | Reads its own backup history (data since deleted from the live system).                                                                                    |
| T9  | Poisons backups: uploads plausible but wrong or backdoored archives, which are restored later.                                                             |
| T10 | The writer key is copied off the host and used from elsewhere, for longer than the host compromise lasts.                                                  |

### From the cloud side

| ID  | Threat                                                                                                                                                      |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| T11 | An operator or project owner account is compromised and used to delete backups, weaken retention, or read objects.                                          |
| T12 | The Terraform identity, or a bad or malicious plan, weakens the setup: grants delete through bucket IAM, adds delete to the writer role, changes lifecycle. |
| T13 | The project is deleted, suspended, or loses billing, and Google deletes its data.                                                                           |
| T14 | A regional outage or loss makes backups unavailable when they're needed.                                                                                    |

### Keys and secrets

| ID  | Threat                                                                                            |
| --- | ------------------------------------------------------------------------------------------------- |
| T15 | The age private keys are lost: every backup becomes unreadable.                                   |
| T16 | The age private keys leak: every backup ever written to those recipients becomes readable.        |
| T17 | The writer key, or the heartbeat URL, leaks through Ansible output, logs, process lists or state. |
| T18 | A leaked heartbeat URL is used to post false "ok" reports, which hides failing backups.           |

### Operational failure

| ID  | Threat                                                                                                                      |
| --- | --------------------------------------------------------------------------------------------------------------------------- |
| T19 | Backups stop silently: the timer is disabled, the host is down, or the script fails without anyone noticing.                |
| T20 | An upload is corrupt, truncated or empty, and is still treated as a backup.                                                 |
| T21 | Too little is backed up: a path is missing, a dump is empty, or a table is truncated, and the backup is valid but useless.  |
| T22 | Too much is backed up (a large directory listed by mistake, or data that grew), and it is billed for every tier's lifetime. |
| T23 | The host's tiers and the bucket's expiry rules disagree, so objects expire too early or are kept too long.                  |
| T24 | A mistaken upload in Locked mode (wrong data, or far too much) can't be removed before it expires.                          |

### Data protection

| ID  | Threat                                                                                                                     |
| --- | -------------------------------------------------------------------------------------------------------------------------- |
| T25 | Personal data is kept in backups longer than the service has promised.                                                     |
| T26 | An erasure request can't reach a locked backup, so erased data survives until the backup expires, and returns if restored. |

### Supply chain

| ID  | Threat                                                                                                                 |
| --- | ---------------------------------------------------------------------------------------------------------------------- |
| T27 | The released collection, or a package it installs (`google-cloud-cli`, `age`), is tampered with.                       |
| T28 | Installing the collection from git corrupts the consuming repository (a clone inside a git hook overwrites its index). |

## Controls

### In place

| ID  | Control                                                                                                                                                                                            | Where                                                   | Addresses         |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- | ----------------- |
| C1  | The writer role has no delete permission, and a Terraform precondition refuses any permission containing "delete".                                                                                 | `modules/project-role/main.tf`                          | T1                |
| C2  | Every object carries a retain-until set at upload. The writer role has no `overrideUnlockedRetention`, so it can't shorten it.                                                                     | `offsite-backup`, `modules/project-role/main.tf`        | T1, T2            |
| C3  | Locked retention mode. Nobody, including the project owner, can delete or shorten a Locked object before it expires.                                                                               | `offsite_backup_retention_mode`                         | T1, T2, T11, T12  |
| C4  | One bucket and one service account per host, bound at bucket level ([ADR 0001](adr/0001-one-bucket-per-host.md)).                                                                                  | `modules/backup-target`                                 | T7                |
| C5  | Archives are encrypted with age to public recipients only. The role refuses a private key as a recipient.                                                                                          | `offsite-backup`, `tasks/validate.yml`                  | T8, T11, T16      |
| C6  | Two recipients: an everyday operator key and an offline recovery key.                                                                                                                              | Consumer; `offsite_backup_age_recipients`               | T15               |
| C7  | Tier contract: before every run, the host checks the bucket's expiry rules against its own tiers and refuses to upload if they differ ([ADR 0003](adr/0003-tier-contract.md)).                     | `offsite-backup`                                        | T23, T25          |
| C8  | Each upload is read back and its size compared with the local archive.                                                                                                                             | `offsite-backup`                                        | T20               |
| C9  | Every run, however it ends, is reported to a heartbeat URL by an `ExecStopPost=` hook. The receiving end alerts on failure and on silence. The timer is `Persistent=`, so a missed run catches up. | `offsite-backup-report`, systemd units                  | T19, T20, T21     |
| C10 | `scripts/restore-test` fetches the newest object, decrypts it and checks for expected entries.                                                                                                     | `scripts/restore-test`                                  | T9, T15, T20, T21 |
| C11 | Writer keys are issued out of band and never stored in Terraform state ([ADR 0002](adr/0002-keys-out-of-band.md)).                                                                                 | `modules/backup-target` output `key_issue_command`      | T17               |
| C12 | Terraform runs as an impersonated identity that can't delete buckets or service accounts, can't read or write backup objects, and can't create keys.                                               | `scripts/bootstrap-project`, `scripts/tf-with-identity` | T11, T12          |
| C13 | Uniform bucket-level access and enforced public access prevention.                                                                                                                                 | `modules/backup-target/main.tf`                         | T8, T16           |
| C14 | A storage class with a minimum storage duration is refused if any tier is shorter than that minimum.                                                                                               | `modules/backup-target/main.tf`                         | T5, T22           |
| C15 | Secret hygiene: the key and report URL are root-only files, `no_log` and `diff: false` keep them out of Ansible output, and the URL isn't on curl's command line.                                  | `tasks/main.yml`, `offsite-backup-report`               | T17, T18          |
| C16 | Fail closed: a missing path, a failing pre-backup hook, failed encryption or an empty archive uploads nothing and reports why.                                                                     | `offsite-backup`                                        | T20, T21          |
| C17 | The collection is installed from the release file built by CI, never from git ([ADR 0005](adr/0005-distribution.md)). Google's apt repository is signed.                                           | `.github/workflows/release.yml`, README                 | T27, T28          |
| C18 | Guidance: start Unlocked and switch to Locked only after a restore test passes. Choose retention from what the service has promised ([`retention.md`](retention.md)).                              | `docs/using-it.md`, `docs/retention.md`                 | T24, T25, T26     |

### Unreleased

| ID  | Control                                                                                                                                                                                                         | Where                       | Addresses |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------- | --------- |
| C19 | Size guard: a required maximum archive size, and a refusal when the archive grew more than a set percentage since the last good run. Both are checked before upload. It guards against mistakes, not attackers. | `offsite-backup`, role vars | T22, T24  |
| C20 | The heartbeat carries the archive size on success, so the receiving end can chart growth and alert on it.                                                                                                       | `offsite-backup-report`     | T21, T22  |

### Proposed

| ID  | Control                                                                                                                                                                                                                          | Addresses    |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ |
| C21 | **Bucket retention policy, one bucket per tier.** Retention is set on the bucket by Terraform, not per object by the host. The writer loses `setRetention`. Each bucket's expiry rule covers every object in it, with no prefix. | T3, T4, T5   |
| C22 | **The host writes only the shortest tier.** A separate trusted job promotes one object per period (the one named for that date, after a size check) into the longer tiers. The host has no access to long-tier buckets.          | T4, T5, T9   |
| C23 | **Unlocked where the host can write, Locked where it can't.** The host-writable bucket gets an unlocked policy and an emergency identity, never on the host, that can clear it. Long-tier buckets get a locked policy.           | T5, T11, T24 |
| C24 | **Detect abnormal writes and disable the writer automatically.** Alert on write request rate or per-object notifications, and disable the writer service account. Disabling deletes nothing and can be undone.                   | T5, T6, T10  |
| C25 | **IAM condition limiting writes to the backup window** (for example two hours a day).                                                                                                                                            | T5, T6, T10  |
| C26 | **Budget alert and bucket size monitoring** for the project.                                                                                                                                                                     | T5, T6, T22  |
| C27 | **Audit alerting** on changes to bucket IAM, bucket configuration and custom roles, and on object deletions or retention overrides.                                                                                              | T11, T12     |
| C28 | **A project lien** against deletion.                                                                                                                                                                                             | T13          |
| C29 | **Writer key age tracking and rotation.**                                                                                                                                                                                        | T10, T17     |
| C30 | **A shrink check** in the backup script: refuse or warn when the archive is far smaller than the last good run.                                                                                                                  | T21          |
| C31 | **Published checksums or signatures** for the release file, verified on install.                                                                                                                                                 | T27          |

C21 to C25 are one design: they replace per-object retention, and
together they bound what a compromised host can cost. The details and
open questions are tracked in
[#7](https://github.com/ledurnan/tf-gcs-backup/issues/7).

## Coverage

What's left after the in-place controls, and what would reduce it.

| Threat                             | In place / unreleased   | Residual risk now                                                                                                                                                                            | Proposed      |
| ---------------------------------- | ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------- |
| T1 delete own backups              | C1, C2, C3              | Low. Needs [#7](https://github.com/ledurnan/tf-gcs-backup/issues/7) step 4 confirmed.                                                                                                        | —             |
| T2 shorten retention               | C2, C3                  | Low. `setRetention` can extend and lock, but should not shorten without the override permission. To be confirmed (#7 step 4).                                                                | C21           |
| T3 never-expiring objects          | —                       | **Open.** Storage grows with no upper limit.                                                                                                                                                 | C21           |
| T4 excessive locked retention      | —                       | **Open.** In Locked mode, undeletable for as long as the attacker chooses.                                                                                                                   | C21, C22      |
| T5 denial of wallet, volume        | C14                     | **Open.** Cost is upload rate × retention, with no upper limit (T3, T4). Highest for hosts with long tiers, worst in Locked mode.                                                            | C21–C26       |
| T6 denial of wallet, requests      | —                       | **Open.** Billed per operation, whatever retention is.                                                                                                                                       | C24, C25, C26 |
| T7 other hosts' backups            | C4                      | Low.                                                                                                                                                                                         | —             |
| T8 read own history                | C5, C13                 | Low. Objects are unreadable without the age keys.                                                                                                                                            | —             |
| T9 poisoned backups                | C10                     | Medium. Older tiers keep earlier good copies, but poisoning that outlasts the longest tier goes undetected unless a restore test checks the content.                                         | C22           |
| T10 stolen writer key              | —                       | **Open.** The key is long-lived and works from anywhere until rotated. Same impact as T3–T6.                                                                                                 | C24, C25, C29 |
| T11 operator compromise            | C3, C5, C12             | Locked objects survive. Unlocked objects can be deleted. Objects stay unreadable without the age keys.                                                                                       | C23, C27      |
| T12 Terraform identity / bad plan  | C1 (code only), C3, C12 | Medium. The identity holds `storage.buckets.setIamPolicy` and `iam.roles.update`, so it could grant delete on Unlocked objects. The precondition in C1 only applies to plans of this module. | C27           |
| T13 project deletion, billing loss | —                       | Medium. A single project is a single point of failure. Whether locked retention blocks project deletion needs checking.                                                                      | C26, C28      |
| T14 regional loss                  | —                       | Consumer's choice of `location`. A dual- or multi-region location reduces it.                                                                                                                | —             |
| T15 age keys lost                  | C6, C10                 | Low if the recovery key is genuinely offline and tested.                                                                                                                                     | —             |
| T16 age keys leak                  | C5                      | Medium. Changing recipients only protects new backups. Locked objects written for the leaked keys can't be removed before they expire.                                                       | —             |
| T17 secrets in output or state     | C11, C15                | Low.                                                                                                                                                                                         | C29           |
| T18 spoofed heartbeat              | C15                     | Low. It needs the URL, which is root-only on the host.                                                                                                                                       | —             |
| T19 silent stop                    | C9                      | Low, provided the receiving end alerts on silence.                                                                                                                                           | —             |
| T20 corrupt or empty upload        | C8, C9, C10, C16        | Low.                                                                                                                                                                                         | —             |
| T21 too little backed up           | C9, C10, C16, C20       | Medium. A dump that succeeds but is nearly empty isn't caught by this repository; consumers' hooks should check their own data.                                                              | C30           |
| T22 too much backed up             | C14, C19, C20           | Low once C19 is released.                                                                                                                                                                    | C26           |
| T23 tier mismatch                  | C7                      | Low.                                                                                                                                                                                         | —             |
| T24 mistaken locked upload         | C18, C19                | Medium. A mistake that passes the size guard still stays for its full tier.                                                                                                                  | C23           |
| T25 retention beyond promise       | C7, C18                 | Consumer's decision, checked against what they've promised.                                                                                                                                  | —             |
| T26 erasure vs locked backups      | C18                     | Accepted by design. Consumers record erasures and reconcile them on restore.                                                                                                                 | —             |
| T27 tampered supply chain          | C17                     | Medium. The release file is fetched over TLS from GitHub but not verified against a checksum.                                                                                                | C31           |
| T28 git install corrupts repo      | C17                     | Low.                                                                                                                                                                                         | —             |

## Keeping this current

Update this document in the same change as any control it describes: a
new control gets a `C` number, a status, and its threats, and the
coverage table is updated. Numbers are never reused.

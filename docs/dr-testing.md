# Testing disaster recovery: a runbook template

A backup counts only once its newest object has been decrypted with every
key you hold for it and restored into something that is not the live
host. [`restore.md`](restore.md) says how to restore one archive; this is
a template for **testing** that you can, on a schedule, and keeping a
record that you did.

Copy it into your own repository (for example as
`docs/dr-testing.md`, with the [results log](#the-results-log) beside it
as `docs/dr-test-log.md`) and fill it in per host. Everything in
`<angle brackets>`, and every `yourorg`, `host-a` and `example` name, is
a placeholder: replace it with yours. Delete what doesn't apply, and
keep what you add in the same shape, so the next person can follow it
without you.

It tests backups. It does not rebuild hosts: your per-host
disaster-recovery runbooks do that, and step 6 checks they still work.

Steps marked **[operator]** need a person who holds the age private keys
and runs them in their own plain terminal. Everything else needs no key
and can be run by anyone, or anything, with read access to the buckets.

## Fill in: the hosts

One row per backed-up host.

| Host     | What its backup holds                                                | Bucket name prefix (tiers)                                            | Google account / project              | age keys (recipients) | Host runbook               |
| -------- | -------------------------------------------------------------------- | --------------------------------------------------------------------- | ------------------------------------- | --------------------- | -------------------------- |
| `host-a` | `<paths>`, plus `offsite-backup-dump/` with `<what the dump writes>` | `yourorg-backup-host-a` (`daily` 7 d, `weekly` 28 d, `monthly` 365 d) | `you@example.com` / `your-project-id` | operator, recovery    | `<link to its DR runbook>` |
| `host-b` | `<paths>`                                                            | `yourorg-backup-host-b` (`daily` 7 d)                                 | `you@example.com` / `your-project-id` | operator, recovery    | `<link>`                   |

- **Tiers:** the host's `offsite_backup_tiers`, with each one's
  `retain_days`. Each tier is a bucket, `<bucket name prefix>-<tier>`.
- **age keys:** every private key that should open the host's backups,
  by name, and where each is kept (the operator key in a password
  manager, the recovery key offline: see [using-it.md](using-it.md),
  step 4). Their public keys are the host's
  `offsite_backup_age_recipients`. A key the test never decrypts with is
  a key you don't know works.
- **Host runbook:** how the host is rebuilt from your IaC, and how its
  backup is restored onto it. Step 6 follows it.

## Rules

- **Never decrypt on the backed-up host, or on any host a backup came
  from.** The hosts hold only public recipients. A private key on a host
  defeats the design: a compromised host could then read its own
  backups.
- **A private key never touches disk, a command's arguments, an
  environment variable or shell history.** Read it with `read -rs` into
  an unexported shell variable and hand it to `age` and `restore-test`
  through a pipe, `--identity <(printf '%s\n' "$AGE_ID")`. Never
  `-i ~/some.key`, never `export` it, never `echo` it.
- **Plaintext lives only in RAM** (`/dev/shm`, a container's tmpfs) and
  only in a shell that can't swap (step 2), or in a container whose
  `--memory-swap` equals its `--memory`. Remove it as soon as the result
  is recorded.
- **A restore target is throwaway and isolated.** Never restore over a
  live host, and never into a development stack you keep. Never let a
  restored service act on the world: anything the backup holds that
  sends, schedules, syncs or claims an identity (a mail queue, a job
  scheduler and its schedule, a VPN or mesh node's state, a webhook
  consumer, a DNS or certificate client) stays stopped, or gets no
  network. List yours here:
  - `host-a`: `<what must not start, and how to keep it stopped>`
- **Change nothing on the backed-up host.** The test only reads it. Don't
  run `offsite-backup` there, not even `--check-contract`, which writes
  to its state directory.
- **Don't download into a directory that is synced or backed up.** The
  `.tar.age` is ciphertext, but its plaintext must not follow it there.

## Levels and cadence

Three levels, each including the one before:

1. **Decrypt proof.** The newest object of every tier decrypts with
   every key, lists, and holds what it should (steps 0–3).
2. **Integrity and data restore.** The archive unpacks, its own
   manifest and checksums pass, its size is in line with history, and
   its data loads into a throwaway container on the operator's machine,
   where your own checks pass (steps 4–5).
3. **Rebuild.** A throwaway host is built from your IaC, the backup is
   restored onto it with the host runbook, and the service comes up and
   passes a smoke test (step 6).

| When                                                                                                             | What                                                                                                                                                                                                 |
| ---------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| After a host's backup is first enabled                                                                           | Level 3, then level 1 on the first object of each other tier as it appears (a weekly tier's first object comes in its first week, a monthly one's in its first month)                                |
| After any change to backed-up paths, recipients, the pre-backup command, the tiers, or an upgrade of this module | Level 2 on the first object written after the change                                                                                                                                                 |
| After rotating an age key                                                                                        | Level 1 with the new key on the first new object, and with the old key on the newest object made before the rotation, until that key may be destroyed ([using-it.md](using-it.md), "Rotating a key") |
| Every `<quarter>`                                                                                                | Level 2, every host, every tier, every key                                                                                                                                                           |
| Every `<year>`, and after a major version change of what the dump holds (a database, the application)            | Level 3                                                                                                                                                                                              |

Choose your own intervals; the ones above are a starting point. Whatever
you choose, write the next due date in the log at the end of each test.

These tests are by hand. `restore-test` can run on a schedule, but only
where a private key is available to it, which these rules keep off every
machine that runs unattended. If your hosts don't report failed runs
(`offsite_backup_report_url` unset), add a monthly look at step 1's
listing, which needs no key: each tier's newest object should be no older
than its schedule allows, and its size in line with the ones before. That
is not a test level and gets no row in the log; record only what it
finds wrong.

## 0. Pre-check

Needs no key and changes nothing.

**On each host**, read only:

```bash
systemctl list-timers offsite-backup.timer        # active, next run scheduled
systemctl status offsite-backup.service --no-pager # last run succeeded, within a day
sudo journalctl -u offsite-backup.service --since -2d --no-pager | tail -20
sudo grep -c '^age1' /etc/offsite-backup/recipients   # the number of keys you expect
sudo grep -rl 'AGE-SECRET-KEY-' /etc /root /home 2>/dev/null   # must print nothing
```

The configuration directory is the role's `offsite_backup_conf_dir`
(`/etc/offsite-backup` by default) and only root can read it. Compare the
recipients in its `recipients` file with the host's `offsite_backup_age_recipients` in your inventory: the same keys,
no more. Look for leftovers of an earlier restore on the host (an
unpacked `offsite-backup-dump/`, a stray `.tar.age`).

**On the operator's machine:** nothing left from an earlier test (step 7's
cleanup), no clipboard manager keeping history, nothing recording the
terminal (`script`, tmux `pipe-pane`, the terminal emulator's own
logging). Check the swap guard works here: from your tf-gcs-backup
checkout, `scripts/issue-age-key --check-guard` must print `OK` first.

A failure here is the test's first finding: record it, then decide
whether to go on.

## 1. List the newest objects

As your own Google account, from the operator's machine. Go by the
creation time in the second column, not by the name: the host chooses
the names, and a compromised host could leave one that sorts last.
`awk 'NF == 3'` drops the `TOTAL:` line gcloud adds at the end.

```bash
export CLOUDSDK_CORE_ACCOUNT=you@example.com CLOUDSDK_CORE_PROJECT=your-project-id
for tier in daily weekly monthly; do
  gcloud storage ls -l "gs://yourorg-backup-host-a-${tier}/host-a/" | awk 'NF == 3' | sort -k2 | tail -3
done
```

`CLOUDSDK_CORE_ACCOUNT` and `CLOUDSDK_CORE_PROJECT` choose the identity
for this shell only, without changing your gcloud configuration, and
`restore-test` uses them the same way. Neither is a secret.

Note each tier's newest object: name, creation time and size. Each goes
in the log.

## 2. Prepare the shell [operator]

This and every later step that uses a key run in **one plain terminal**:
not a multiplexer pane, not inside an AI agent's session, not a recorded
session. Keep that terminal for the whole test and close it at the end.

**Swap.** Anything in RAM, the key and the plaintext in `/dev/shm`
included, can be written to swap. Start a shell in a systemd scope that
may not swap, and run every later step in it
([swap guard](swap-guard.md)):

```bash
systemd-run --user --scope -p MemorySwapMax=0 -p MemoryZSwapMax=0 bash
cat "/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)/memory.swap.max"   # must print 0
```

What this shell runs, and the tmpfs files it writes, are charged to the
scope, which can't swap. Remove `$W` before leaving it: once the scope
ends, what is left in `/dev/shm` can be swapped again. Containers run
under the container daemon, outside the scope: give every one
`--memory-swap` equal to `--memory`, as below. The guard doesn't help
against hibernation: don't suspend to disk during the test.

**Work directory and history.**

```bash
unset HISTFILE                          # nothing from this shell reaches your history file
umask 077
W="$(mktemp -d -p /dev/shm dr-XXXXXX)"  # RAM only
mkdir "$W/tmp" "$W/x"
export TMPDIR="$W/tmp"                  # restore-test's scratch copy goes here, in RAM
df -h /dev/shm                          # room for about 3 times the largest object
TG=<path to a checkout of tf-gcs-backup at the release the hosts run>
export CLOUDSDK_CORE_ACCOUNT=you@example.com CLOUDSDK_CORE_PROJECT=your-project-id
```

Everything decrypted goes to `/dev/shm`, which is usually half the RAM.
The fetched object, its decrypted copy and the unpacked archive need
about three times the size of the largest object from step 1. If
`/dev/shm` hasn't that room, stop here, before a key is loaded, rather
than run out part way through.

## 3. Decrypt proof: every tier, every key [operator]

Repeat this step once **per key** in the host table: the operator key,
then the recovery key, and any other. Each pass proves that key on the
newest object of every tier.

**Load the key.** Copy the private key (the `AGE-SECRET-KEY-1…` line)
from where it is kept, or type it from the offline copy, and paste it at
the silent prompt:

```bash
read -rs AGE_ID; echo
age-keygen -y <(printf '%s\n' "$AGE_ID")   # prints the PUBLIC key
```

The public key printed must be one of the host's
`offsite_backup_age_recipients`, and the one you meant to load. If it
isn't, stop: the key you hold does not open these backups, and that is
the headline finding. Clear the clipboard.

`printf` is a shell builtin, so the key never appears in a process's
arguments, and `<(…)` hands it over through a pipe, never a file. Write
down the public key's first 12 and last 6 characters: in the log, that
is "which key decrypted which object".

**Prove every tier.** [`scripts/restore-test`](../scripts/restore-test)
fetches the newest object by creation time, decrypts it, lists it and
checks each `--expect` entry is present. It extracts nothing, and with
`TMPDIR` set as above its scratch copy is in RAM. Each call needs its
own `<(…)`, since a pipe can be read once. `--max-age` is in hours: a
little over the tier's interval (26 for daily, 170 for weekly, 770 for
monthly), so a backup that has stopped fails rather than passing on an
old object.

```bash
for tier in daily:26 weekly:170 monthly:770; do
  "$TG/scripts/restore-test" --bucket-prefix yourorg-backup-host-a \
    --tier "${tier%:*}" --prefix host-a \
    --identity <(printf '%s\n' "$AGE_ID") --max-age "${tier#*:}" \
    --expect offsite-backup-dump/<your dump file> \
    --expect <a backed-up path, e.g. etc/yourapp/>
done
```

Leave out a tier that has no object yet. For a bucket written by v0.1
(every tier in one bucket), pass `--bucket <bucket>` in place of
`--bucket-prefix`. Each run ends `PASS: <object> decrypts and holds <n>
entries…` or `FAIL: <reason>`, and exits non-zero on failure. Record one
log row per object and key.

Then forget the key before loading the next one:

```bash
unset AGE_ID
```

Steps 4 and 5 need only one key: load the operator key again.

## 4. Unpack and check integrity [operator]

Fetch the object `restore-test` named, decrypt it into RAM and unpack it
there. Repeat for each object you restore in step 5.

```bash
obj=gs://yourorg-backup-host-a-daily/host-a/<object>.tar.age   # from step 1 or 3
gcloud storage cp "$obj" "$W/obj.tar.age"
age -d -i <(printf '%s\n' "$AGE_ID") "$W/obj.tar.age" | tar -xz -C "$W/x"
ls "$W/x" "$W/x/offsite-backup-dump"
```

**The dump's own checks.** The module archives whatever your pre-backup
command writes; it adds no manifest of its own. If your dump writes
checksums and a manifest (it should: row counts, versions, the time it
was taken), check them here. For example:

```bash
cd "$W/x/offsite-backup-dump"
sha256sum -c <your checksum file>                 # every line must say OK
grep -E '^(<taken_at>|<db_version>|<app_version>):' <your manifest>
cd -
```

Record the versions the manifest names: step 5 restores with them.

**Files.** For backed-up paths with no manifest, check what matters and
compare it with what is live, without printing a private key. For
example, a certificate's subject, expiry and fingerprint against the one
the service serves, or SSH host keys against the fingerprints you
already trust:

```bash
openssl x509 -in "$W/x/etc/<path to cert.pem>" -noout -subject -enddate -fingerprint -sha256
openssl s_client -connect <host.example>:443 -servername <host.example> </dev/null 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256
for k in "$W"/x/etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$k"; done
```

A certificate renewed since the backup shows a different fingerprint and
a later expiry live: that is fine, and worth a note.

**Size.** Compare each object's size with its earlier log rows and with
its neighbours in step 1. A change of more than `<25%>` either way
without a known reason is a finding. (The host's own size guard,
`offsite_backup_max_growth_percent`, catches growth at backup time; it
does not catch a backup that shrank.)

## 5. Restore into a throwaway container [operator]

Level 2: the data, on the operator's machine, with no network. Use the
versions the manifest names. Give every container a memory limit, an
equal `--memory-swap`, a CPU limit, `--network none`, and its data
directory on a tmpfs, and remove it at the end. For example, a
PostgreSQL custom-format dump:

```bash
v=<postgres version from the manifest>
docker run -d --name dr-db --network none \
  --memory 2g --memory-swap 2g --cpus 2 --tmpfs /var/lib/postgresql:size=1g \
  -e POSTGRES_HOST_AUTH_METHOD=trust -v "$W/x/offsite-backup-dump:/d:ro" "postgres:$v"
until docker exec dr-db pg_isready -q -h 127.0.0.1; do sleep 2; done
docker exec dr-db createdb -U postgres restored
docker exec dr-db pg_restore -U postgres -d restored --no-owner /d/<your dump file>
```

Then run your own verification against it, and record each result:

- `<row counts of the tables that matter, against the manifest>`
- `<a query the application depends on, or its migrations' head>`
- `<an application smoke test against the restored data, network still off>`
- `<a check that any secret the data is encrypted with still opens it>`

If your project already has a restore-test script of its own, run it
here instead, and say so.

```bash
docker rm -f dr-db
```

## 6. Rebuild on a throwaway host (level 3)

Level 3 proves the other half of recovery: that what is **not** in the
archive (the operating system, packages, configuration, the service
itself) is rebuilt from your IaC, and that the archive is enough on top
of it. A throwaway host costs time or money, so agree it first.

1. Build a throwaway host from your IaC with the host runbook, as you
   would after losing the real one, with only the inventory or variables
   changed: its own name and address, and none of the live host's
   network identities (DNS records, VPN or mesh membership, inbound
   routes, webhook endpoints).
2. Restore the backup onto it with the host runbook, using the versions
   the manifest names.
3. Keep stopped everything the [rules](#rules) list as acting on the
   world, then start the rest and run your smoke test:
   `<log in, read a record, render a page; whatever proves the service is
back>`.
4. Note every step where the runbook was wrong, missing or needed
   something only you knew. Each is a finding: fix the runbook, or open
   an issue for it.
5. Record how long it took, from the first command to the smoke test
   passing: it is your measured recovery time.

Destroy the throwaway host once the result is recorded, and remove
anything it was given (credentials, DNS records).

## 7. Record and clean up [operator]

Add a row per object and key to the log, and set the next due date.
Then, in the same terminal:

```bash
unset AGE_ID
rm -rf "$W"
docker rm -f dr-db 2>/dev/null || true   # and any other container you started
exit                    # leaves the guarded shell, after $W is gone
```

Clear the clipboard and close the terminal.

## The results log

Copy this into your repository beside the runbook, as
`docs/dr-test-log.md`. Newest first, one row per object and key.

```markdown
# DR test log

Results of [dr-testing.md](dr-testing.md), newest first.

## Next due

| Host     | Next test    | Level | Why                     |
| -------- | ------------ | ----- | ----------------------- |
| `host-a` | `YYYY-MM-DD` | 2     | quarterly               |
| `host-b` | `YYYY-MM-DD` | 3     | first test after enable |

## Results

| Date       | Host     | Tier  | Object               | Created (UTC)        | Size (B) | Key                              | Level | Checks                                        | Time   | Outcome | By      |
| ---------- | -------- | ----- | -------------------- | -------------------- | -------- | -------------------------------- | ----- | --------------------------------------------- | ------ | ------- | ------- |
| YYYY-MM-DD | `host-a` | daily | `YYYY-MM-DD.tar.age` | YYYY-MM-DDThh:mm:ssZ | 12345678 | `age1xxxxxxxx…yyyyyy` (operator) | 2     | checksums OK; row counts match; smoke test OK | 25 min | PASS    | `<who>` |
| YYYY-MM-DD | `host-a` | daily | `YYYY-MM-DD.tar.age` | YYYY-MM-DDThh:mm:ssZ | 12345678 | `age1zzzzzzzz…wwwwww` (recovery) | 1     | decrypts, every `--expect` present            | 5 min  | PASS    | `<who>` |
```

- **Key:** the first 12 and last 6 characters of the public key that the
  private key derived in step 3, and the key's name.
- **Level:** 1 decrypt proof, 2 integrity and container restore, 3
  rebuild on a throwaway host.
- **Checks:** what passed, or what failed and why, briefly. Link an issue
  for each failure.
- **Time:** how long the test took, for that row's level.
- **Outcome:** PASS or FAIL. A row is PASS only if every check at its
  level passed.

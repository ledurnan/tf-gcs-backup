# Keeping keys out of swap

A private key in memory, or in a file on tmpfs, can be written to a swap
device. If that device isn't encrypted, the key is then on a disk in
plaintext, and stays there until the space is reused. Turning swap off
with `swapoff` before handling a key works, but it is easy to forget,
it needs root, and it affects everything else running.

A cgroup with swap turned off does the same for just the processes that
handle the key:

```bash
systemd-run --user --scope -p MemorySwapMax=0 -p MemoryZSwapMax=0 bash
```

That starts a shell in a new systemd scope, on the same terminal. Every
page that shell and the commands it runs use, including the tmpfs files
they write, is charged to the scope's cgroup, which may not swap.
`MemoryZSwapMax=0` keeps the pages out of zswap's compressed cache as
well. Under memory pressure the kernel reclaims other memory, or kills a
process in the scope, rather than swap these pages.

## issue-age-key

[`scripts/issue-age-key`](../scripts/issue-age-key) does this itself.
On start it reads its cgroup from `/proc/self/cgroup`, and counts as
guarded only if that cgroup's `memory.swap.max` is `0`, and its
`memory.zswap.max` too where the kernel has zswap. Otherwise it runs
itself again, with the same arguments, through the command above, in the
foreground on the same terminal. Its work directory is created inside the
scope and removed before it exits.

If systemd can't create the scope (no user session, the memory
controller not delegated to the user manager, or systemd too old to know
`MemoryZSwapMax`), it **refuses to run** and says why. The key was not
generated.

`--allow-swap` overrides that, but only when no active swap device could
write memory to a disk in plaintext: each one in `/proc/swaps` must be
zram, which is in RAM, or on dm-crypt, including LVM built only on
dm-crypt. A device it can't trace to dm-crypt, such as a swap file on
btrfs, counts as unencrypted. With no swap at all, `--allow-swap` is
accepted. When the guard works, `--allow-swap` is ignored.

`--check-guard` makes no key. It reports whether this process is guarded,
whether a guarded scope can be created (it starts one and asks again from
inside), and what `--allow-swap` would find. It exits 0 when issuing a
key would run guarded and 1 when it would refuse. It runs anywhere, Claude
Code included.

## What it needs

- cgroup v2, with the memory controller delegated to the systemd user
  manager. Check with:

  ```bash
  cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers
  ```

  `memory` must be in the list. Current Debian and Ubuntu releases
  delegate it by default.

- A systemd user session (`systemd-run --user` needs the user manager's
  D-Bus), so a login session, not `sudo -u` or a bare `su`.
- systemd 253 or later, for `MemoryZSwapMax`.

## What it doesn't protect against

- **Root.** Root can read any process's memory and change the cgroup's
  limits.
- **Hibernation.** Suspending to disk writes all memory, the scope's
  included, to the swap device. Don't hibernate while a key is in use.
- **A compromised machine.** Anything that can run code as you can read
  the key from the terminal or the password manager.
- **Copies made outside the scope**: the clipboard, a terminal that
  records its output, or a key file written somewhere else.

## Decrypting and restoring

Use the same scope for anything that handles a private age key, such as
decrypting a backup to test a restore:

```bash
systemd-run --user --scope -p MemorySwapMax=0 -p MemoryZSwapMax=0 bash
# inside that shell: read the key, decrypt, restore, then exit
```

Work in a tmpfs directory created inside that shell (for example under
`/dev/shm`), and delete it before you leave the shell: tmpfs pages are
charged to the scope only while it exists.

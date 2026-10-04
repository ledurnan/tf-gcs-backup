"""Keeping a process's memory out of swap: a cgroup with swap turned off.

A key held in memory, or in a tmpfs file, can be written to a swap device
in plaintext. A systemd scope with MemorySwapMax=0 stops that for every
process in the scope: their pages, and the tmpfs pages they write, are
charged to the scope's cgroup, which may not swap. MemoryZSwapMax=0 also
keeps them out of zswap's compressed cache.

  status()           whether this process is in such a cgroup now
  scope_command()    the systemd-run command that re-runs it inside one
  probe_scope()      whether systemd can create one here
  unsafe_swaps()     the active swap devices that aren't encrypted or in RAM

Every path is read under a root, "/" normally, so the tests can give fake
/proc and /sys trees.
"""

import os
import re
import subprocess
from pathlib import Path

PROPERTIES = ("MemorySwapMax=0", "MemoryZSwapMax=0")
CGROUP_MOUNT = "sys/fs/cgroup"


class Status:
    def __init__(self, protected, reason, cgroup=""):
        self.protected = protected
        self.reason = reason
        self.cgroup = cgroup


def _read(path):
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except OSError:
        return None


def status(root="/"):
    """Whether this process's cgroup has swap, and zswap where the kernel
    has it, limited to 0."""
    root = Path(root)
    lines = (_read(root / "proc/self/cgroup") or "").splitlines()
    unified = [line[3:] for line in lines if line.startswith("0::")]
    if not unified:
        return Status(False, "this system isn't using cgroup v2, so a cgroup can't turn swap off")
    cgroup = unified[0]
    cg_dir = root / CGROUP_MOUNT / cgroup.lstrip("/")
    swap = _read(cg_dir / "memory.swap.max")
    if swap is None:
        return Status(False, "the memory controller isn't enabled for this process's cgroup", cgroup)
    if swap != "0":
        return Status(False, f"this process's cgroup may swap (memory.swap.max is {swap})", cgroup)
    zswap = _read(cg_dir / "memory.zswap.max")
    if zswap is not None and zswap != "0":
        return Status(False, f"this process's cgroup may use zswap (memory.zswap.max is {zswap})", cgroup)
    return Status(True, "swap is off for this process's cgroup (memory.swap.max 0, memory.zswap.max 0)", cgroup)


def scope_command(command):
    """systemd-run running command in the foreground, on this terminal, in
    a new user scope that may not swap."""
    props = [arg for prop in PROPERTIES for arg in ("-p", prop)]
    return ["systemd-run", "--user", "--scope", "--quiet", *props, "--", *command]


def probe_scope():
    """None if systemd can create a scope that may not swap; otherwise why
    not."""
    try:
        result = subprocess.run(
            scope_command(["true"]), capture_output=True, text=True, check=False, stdin=subprocess.DEVNULL
        )
    except FileNotFoundError:
        return "systemd-run is not installed"
    except OSError as e:
        return f"systemd-run could not be run: {e}"
    if result.returncode != 0:
        return result.stderr.strip() or f"systemd-run exited {result.returncode}"
    return None


# --- Swap devices ----------------------------------------------------------


def _unescape(name):
    """/proc/swaps writes a space in a path as \\040."""
    return re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), name)


def swaps(root="/"):
    """The active swap devices: (path, type) pairs."""
    text = _read(Path(root) / "proc/swaps")
    if text is None:
        raise OSError("can't read /proc/swaps")
    found = []
    for line in text.splitlines()[1:]:
        fields = line.split()
        if len(fields) >= 2:
            found.append((_unescape(fields[0]), fields[1]))
    return found


def device_of(path, kind):
    """The block device holding a swap area, as "major:minor": the device
    itself for a partition, the filesystem's device for a file."""
    st = os.stat(path)
    dev = st.st_rdev if kind == "partition" else st.st_dev
    return f"{os.major(dev)}:{os.minor(dev)}"


def _encrypted(dev_dir, depth=0):
    """A dm-crypt device, or one built only on dm-crypt devices (LVM on
    LUKS, for example)."""
    if depth > 16:
        return False
    uuid = _read(dev_dir / "dm" / "uuid") or ""
    if uuid.startswith("CRYPT-"):
        return True
    slaves = dev_dir / "slaves"
    under = sorted(slaves.iterdir()) if slaves.is_dir() else []
    return bool(under) and all(_encrypted(d, depth + 1) for d in under)


def unsafe_swaps(root="/", device=device_of):
    """The active swap devices that could write memory to a disk in
    plaintext, each with why. zram is in RAM; dm-crypt is encrypted. A
    device that can't be traced to dm-crypt counts as unsafe."""
    root = Path(root)
    unsafe = []
    for path, kind in swaps(root):
        if re.fullmatch(r"/dev/zram\d+", path):
            continue
        try:
            dev = device(path, kind)
        except OSError as e:
            unsafe.append((path, f"can't find its device: {e.strerror or e}"))
            continue
        dev_dir = root / "sys/dev/block" / dev
        if not dev_dir.exists():
            unsafe.append((path, f"its device {dev} isn't a block device this can trace"))
        elif not _encrypted(dev_dir):
            what = "a file on an unencrypted device" if kind == "file" else "an unencrypted device"
            unsafe.append((path, what))
    return unsafe

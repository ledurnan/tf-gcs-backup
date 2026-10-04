"""scripts/_swapguard.py against fake /proc and /sys trees: whether this
process is in a cgroup that may not swap, the systemd-run command, and
which swap devices could write memory to a disk in plaintext."""

import importlib.machinery
import importlib.util
import os
import sys
from pathlib import Path

import _swapguard
import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "issue-age-key"
SWAPS_HEADER = "Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority"


def fake_root(root, *, swap="0", zswap="0", cgroup="0::/user.slice/test.scope", swaps=()):
    """A /proc and /sys for the guard to read: this process's cgroup line,
    its memory.swap.max and memory.zswap.max (None: no such file), and
    /proc/swaps lines ("path type")."""
    (root / "proc/self").mkdir(parents=True)
    (root / "proc/self/cgroup").write_text(cgroup + "\n")
    lines = [SWAPS_HEADER] + [f"{entry}\t\t8388604\t\t0\t\t-2" for entry in swaps]
    (root / "proc/swaps").write_text("\n".join(lines) + "\n")
    if cgroup.startswith("0::"):
        cg_dir = root / "sys/fs/cgroup" / cgroup[3:].lstrip("/")
        cg_dir.mkdir(parents=True)
        for name, value in (("memory.swap.max", swap), ("memory.zswap.max", zswap)):
            if value is not None:
                (cg_dir / name).write_text(value + "\n")
    return root


# --- status ----------------------------------------------------------------


def test_protected_when_swap_and_zswap_are_0(tmp_path):
    st = _swapguard.status(fake_root(tmp_path))
    assert st.protected
    assert st.cgroup == "/user.slice/test.scope"


def test_protected_without_zswap_in_the_kernel(tmp_path):
    assert _swapguard.status(fake_root(tmp_path, zswap=None)).protected


@pytest.mark.parametrize(
    ("kwargs", "reason"),
    [
        ({"swap": "max"}, "may swap (memory.swap.max is max)"),
        ({"swap": "1048576"}, "may swap (memory.swap.max is 1048576)"),
        ({"zswap": "max"}, "may use zswap (memory.zswap.max is max)"),
        ({"swap": None, "zswap": None}, "memory controller isn't enabled"),
        ({"cgroup": "4:memory:/user.slice\n1:name=systemd:/user.slice"}, "isn't using cgroup v2"),
        ({"cgroup": ""}, "isn't using cgroup v2"),
    ],
    ids=["swap max", "swap limited", "zswap max", "no memory controller", "cgroup v1", "no cgroup"],
)
def test_not_protected(tmp_path, kwargs, reason):
    st = _swapguard.status(fake_root(tmp_path, **kwargs))
    assert not st.protected
    assert reason in st.reason


def test_unreadable_proc_is_not_protected(tmp_path):
    assert not _swapguard.status(tmp_path).protected


# --- The commands ----------------------------------------------------------


def test_scope_command():
    assert _swapguard.scope_command(["prog", "--a", "b c"]) == [
        "systemd-run",
        "--user",
        "--scope",
        "--quiet",
        "-p",
        "MemorySwapMax=0",
        "-p",
        "MemoryZSwapMax=0",
        "--",
        "prog",
        "--a",
        "b c",
    ]


def load_script():
    loader = importlib.machinery.SourceFileLoader("issue_age_key", str(SCRIPT))
    spec = importlib.util.spec_from_loader("issue_age_key", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def test_the_rerun_is_the_same_interpreter_script_and_arguments():
    argv = ["--name", "recovery", "--work-dir", "/dev/shm", "--retain-days", "35"]
    command = load_script().rerun_command(argv)
    assert command == [*_swapguard.scope_command([]), sys.executable, str(SCRIPT), *argv]


def fake_systemd_run(tmp_path, monkeypatch, body):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    (bin_dir / "systemd-run").write_text(f"#!/bin/sh\n{body}\n")
    (bin_dir / "systemd-run").chmod(0o755)
    monkeypatch.setenv("PATH", str(bin_dir))


def test_probe_scope_works(tmp_path, monkeypatch):
    fake_systemd_run(tmp_path, monkeypatch, "exit 0")
    assert _swapguard.probe_scope() is None


def test_probe_scope_gives_systemds_reason(tmp_path, monkeypatch):
    fake_systemd_run(tmp_path, monkeypatch, "echo 'Unknown assignment: MemoryZSwapMax=0' >&2; exit 1")
    assert _swapguard.probe_scope() == "Unknown assignment: MemoryZSwapMax=0"


def test_probe_scope_without_systemd_run(tmp_path, monkeypatch):
    monkeypatch.setenv("PATH", str(tmp_path))
    assert _swapguard.probe_scope() == "systemd-run is not installed"


# --- Swap devices ----------------------------------------------------------


def block_dev(root, dev, *, uuid=None, slaves=()):
    """A /sys/dev/block/<major:minor> entry: a dm uuid, and the devices it
    is built on (each a (uuid, slaves) pair)."""
    d = root / "sys/dev/block" / dev
    d.mkdir(parents=True)
    if uuid:
        (d / "dm").mkdir()
        (d / "dm/uuid").write_text(uuid + "\n")
    for i, (s_uuid, s_slaves) in enumerate(slaves):
        sub = d / "slaves" / f"dm-{i}"
        sub.mkdir(parents=True)
        if s_uuid:
            (sub / "dm").mkdir()
            (sub / "dm/uuid").write_text(s_uuid + "\n")
        for j, s in enumerate(s_slaves):
            (sub / "slaves" / f"sd{j}").mkdir(parents=True)
            if s:
                (sub / "slaves" / f"sd{j}" / "dm").mkdir()
                (sub / "slaves" / f"sd{j}" / "dm/uuid").write_text(s + "\n")
    return d


DEVICES = {
    "/swap.img": "8:2",
    "/dev/sda3": "8:3",
    "/dev/mapper/cryptswap": "253:0",
    "/dev/vg/swap": "253:1",
    "/dev/vg/mixed": "253:2",
    "/my swap": "8:2",
}


def unsafe(root):
    return _swapguard.unsafe_swaps(root, device=lambda path, _kind: DEVICES[path])


def test_no_swap_is_safe(tmp_path):
    assert unsafe(fake_root(tmp_path)) == []


def test_zram_is_safe(tmp_path):
    assert unsafe(fake_root(tmp_path, swaps=["/dev/zram0 partition", "/dev/zram12 partition"])) == []


def test_a_swap_file_on_a_plain_disk_is_unsafe(tmp_path):
    root = fake_root(tmp_path, swaps=["/swap.img file", "/dev/zram0 partition"])
    block_dev(root, "8:2")
    assert unsafe(root) == [("/swap.img", "a file on an unencrypted device")]


def test_a_plain_partition_is_unsafe(tmp_path):
    root = fake_root(tmp_path, swaps=["/dev/sda3 partition"])
    block_dev(root, "8:3")
    assert unsafe(root) == [("/dev/sda3", "an unencrypted device")]


def test_dm_crypt_is_safe(tmp_path):
    root = fake_root(tmp_path, swaps=["/dev/mapper/cryptswap partition"])
    block_dev(root, "253:0", uuid="CRYPT-PLAIN-cryptswap")
    assert unsafe(root) == []


def test_lvm_on_luks_is_safe(tmp_path):
    root = fake_root(tmp_path, swaps=["/dev/vg/swap partition"])
    block_dev(root, "253:1", uuid="LVM-abc", slaves=[("CRYPT-LUKS2-abc-root", [None])])
    assert unsafe(root) == []


def test_lvm_partly_on_luks_is_unsafe(tmp_path):
    root = fake_root(tmp_path, swaps=["/dev/vg/mixed partition"])
    block_dev(root, "253:2", uuid="LVM-abc", slaves=[("CRYPT-LUKS2-abc", [None]), (None, [])])
    assert unsafe(root) == [("/dev/vg/mixed", "an unencrypted device")]


def test_lvm_on_plain_disk_is_unsafe(tmp_path):
    root = fake_root(tmp_path, swaps=["/dev/vg/swap partition"])
    block_dev(root, "253:1", uuid="LVM-abc", slaves=[(None, [])])
    assert unsafe(root) == [("/dev/vg/swap", "an unencrypted device")]


def test_a_path_with_a_space(tmp_path):
    root = fake_root(tmp_path, swaps=["/my\\040swap file"])
    block_dev(root, "8:2")
    assert unsafe(root) == [("/my swap", "a file on an unencrypted device")]


def test_an_untraceable_device_is_unsafe(tmp_path):
    root = fake_root(tmp_path, swaps=["/swap.img file"])  # no /sys entry: btrfs, NFS...
    assert unsafe(root) == [("/swap.img", "its device 8:2 isn't a block device this can trace")]


def test_a_swap_device_that_cant_be_found_is_unsafe(tmp_path):
    root = fake_root(tmp_path, swaps=["/no/such/swap file"])
    assert _swapguard.unsafe_swaps(root) == [("/no/such/swap", "can't find its device: No such file or directory")]


def test_unreadable_proc_swaps_raises(tmp_path):
    with pytest.raises(OSError):
        _swapguard.unsafe_swaps(tmp_path)


def test_the_real_device_of_a_file(tmp_path):
    f = tmp_path / "f"
    f.write_text("")
    st = f.stat()
    major, minor = _swapguard.device_of(str(f), "file").split(":")
    assert os.makedev(int(major), int(minor)) == st.st_dev

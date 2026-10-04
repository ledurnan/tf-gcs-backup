"""scripts/issue-age-key, run in a pseudo-terminal as a person would run it.

age and age-keygen are the real tools, behind wrappers that log every
argument and environment variable they are given, so a test can check the
private key never reached either.
"""

import os
import pty
import re
import select
import shutil
import signal
import subprocess
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "issue-age-key"
ALT_ON = b"\x1b[?1049h"
ALT_OFF = b"\x1b[?1049l"
PUBLIC = rb"Public key:   (age1[0-9a-z]+)"
SECRET = rb"Private key:  (AGE-SECRET-KEY-1[0-9A-Z]+)"
PROMPT = rb"paste the private key back"
AGAIN = rb"Show the key again\? \[y/N\] "
BECH32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l".upper()

pytestmark = pytest.mark.skipif(not shutil.which("age-keygen"), reason="age is not installed")


WRAPPER = """#!/bin/bash
{{ printf 'ARGS:'; printf ' %q' "$@"; echo; env; }} >>"$WRAP_LOG"
if [ -n "${{SLOW_KEYGEN:-}}" ] && [ "$1" = -o ]; then touch "$SLOW_KEYGEN"; sleep 2; fi
exec {real} "$@"
"""


@pytest.fixture
def ctx(tmp_path):
    """The environment the script runs in: logging wrappers first on PATH,
    a work directory, and no CLAUDECODE (these tests may run inside
    Claude Code)."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for tool in ("age", "age-keygen"):
        wrapper = bin_dir / tool
        wrapper.write_text(WRAPPER.format(real=shutil.which(tool)))
        wrapper.chmod(0o755)
    work = tmp_path / "work"
    work.mkdir()
    env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    env["WRAP_LOG"] = str(tmp_path / "wrap.log")

    class Ctx:
        pass

    c = Ctx()
    c.tmp, c.work, c.env, c.log = tmp_path, work, env, tmp_path / "wrap.log"
    c.args = ["--name", "operator", "--work-dir", str(work), "--allow-disk-work-dir"]
    return c


class Term:
    """The script in a pseudo-terminal: its stdin, stdout and stderr, and
    its controlling terminal, as in a real one."""

    def __init__(self, args, env):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:  # the child
            os.execve(str(SCRIPT), [str(SCRIPT), *args], env)
        self.out = b""
        self.mark = 0
        self.rc = None

    def _read(self, timeout):
        ready, _, _ = select.select([self.fd], [], [], timeout)
        if not ready:
            return True
        try:
            data = os.read(self.fd, 4096)
        except OSError:  # EIO: the script has exited
            return False
        self.out += data
        return bool(data)

    def expect(self, pattern, timeout=20):
        rx = re.compile(pattern)
        deadline = time.monotonic() + timeout
        while True:
            m = rx.search(self.out, self.mark)
            if m:
                self.mark = m.end()
                return m
            left = deadline - time.monotonic()
            if left <= 0 or not self._read(left):
                raise AssertionError(f"{pattern!r} not seen in:\n{self.out.decode(errors='replace')}")

    def send(self, text):
        os.write(self.fd, text.encode())

    def finish(self, timeout=60):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and self._read(deadline - time.monotonic()):
            pass
        _, status = os.waitpid(self.pid, 0)
        os.close(self.fd)
        self.rc = os.waitstatus_to_exitcode(status)
        return self.rc

    def normal_screen(self):
        """What reached the normal screen: everything outside the
        alternate screen."""
        return re.sub(re.escape(ALT_ON) + rb".*?(" + re.escape(ALT_OFF) + rb"|$)", b"", self.out, flags=re.S)

    def left_alt_screen(self):
        return self.out.rfind(ALT_ON) < self.out.rfind(ALT_OFF) or ALT_ON not in self.out


def other_secret():
    """The private key of a different, valid pair."""
    out = subprocess.run(["age-keygen"], capture_output=True, text=True, check=True).stdout
    return re.search(r"AGE-SECRET-KEY-1[0-9A-Z]+", out).group(0)


def typo(secret):
    """secret with one character changed: still the right form, but its
    checksum fails."""
    i = len(secret) - 10
    return secret[:i] + next(ch for ch in BECH32 if ch != secret[i]) + secret[i + 1 :]


def shown(term):
    """Wait for the key on the alternate screen; its public and private
    halves."""
    public = term.expect(PUBLIC).group(1)
    secret = term.expect(SECRET).group(1)
    term.expect(rb"Press Enter")
    return public.decode(), secret.decode()


def assert_clean(ctx, term, secret=None):
    """The work directory is gone, the alternate screen was left, and the
    private key never reached the normal screen or the tools' arguments
    and environment."""
    assert list(ctx.work.iterdir()) == []
    assert term.left_alt_screen()
    if secret:
        assert secret.encode() not in term.normal_screen()
        assert secret not in (ctx.log.read_text() if ctx.log.exists() else "")


# --- The success path ------------------------------------------------------


def test_issues_a_key_proved_saved(ctx):
    term = Term(ctx.args, ctx.env)
    public, secret = shown(term)
    term.send("\n")
    term.expect(PROMPT)
    term.send(secret + "\n")
    assert term.finish() == 0
    normal = term.normal_screen()
    assert b"the operator key is issued" in normal
    assert public.encode() in normal
    assert b"offsite_backup_age_recipients" in normal
    # Shown once, and the paste back wasn't echoed.
    assert term.out.count(secret.encode()) == 1
    assert_clean(ctx, term, secret)

    # The saved key decrypts what is encrypted to the printed public key.
    identity = ctx.tmp / "saved.key"
    identity.write_text(secret + "\n")
    enc = subprocess.run(["age", "-r", public], input=b"backup", capture_output=True, check=True).stdout
    dec = subprocess.run(["age", "-d", "-i", str(identity)], input=enc, capture_output=True, check=True)
    assert dec.stdout == b"backup"


def test_recovery_key_says_offline_and_gives_a_keep_until_date(ctx):
    args = ["--name", "recovery", "--retain-days", "365", "--slack-days", "2", *ctx.args[2:]]
    term = Term(args, ctx.env)
    term.expect(rb"OFFLINE")
    _, secret = shown(term)
    term.send("\n")
    term.expect(PROMPT)
    term.send(secret + "\n")
    assert term.finish() == 0
    keep = rb"365 \+ 2 = 367 days after the hosts stop using it \(if they stopped today, until \d{4}-\d\d-\d\d\)"
    assert re.search(keep, term.out)
    assert_clean(ctx, term, secret)


def test_a_wrong_paste_then_the_right_one_issues_it(ctx):
    term = Term(ctx.args, ctx.env)
    _, secret = shown(term)
    term.send("\n")
    term.expect(PROMPT)
    term.send("not a key\n")
    term.expect(AGAIN)
    term.send("\n")
    term.expect(PROMPT)
    term.send(secret + "\n")
    assert term.finish() == 0
    assert b"is issued" in term.out
    assert_clean(ctx, term, secret)


# --- Pasting back the wrong thing ------------------------------------------


def test_wrong_key_then_another_pair_then_a_typo_runs_out_of_tries(ctx):
    term = Term(ctx.args, ctx.env)
    public, secret = shown(term)
    term.send("\n")

    term.expect(PROMPT)
    term.send("hunter2\n")
    term.expect(rb"isn't an age private key")
    term.expect(AGAIN)
    term.send("n\n")

    term.expect(PROMPT)
    term.send(other_secret() + "\n")
    term.expect(rb"a different one from the key just generated")
    term.expect(AGAIN)
    term.send("y\n")
    assert shown(term)[1] == secret  # shown again, the same key
    term.send("\n")

    term.expect(PROMPT)
    term.send(typo(secret) + "\n")
    term.expect(rb"a character is wrong or missing")
    assert term.finish() == 1
    assert term.out.count(ALT_ON) == 2
    normal = term.normal_screen()
    assert b"didn't match the new operator key in 3 tries" in normal
    assert f"NOT issued. Don't use its public key ({public})".encode() in normal
    assert b"is issued" not in normal
    assert_clean(ctx, term, secret)


# --- Refusals --------------------------------------------------------------


def run_with(ctx, stdin, stdout, env=None):
    return subprocess.run(
        [str(SCRIPT), *ctx.args], stdin=stdin, stdout=stdout, stderr=subprocess.PIPE, env=env or ctx.env, check=False
    )


def test_refuses_stdin_that_isnt_a_terminal(ctx):
    master, slave = os.openpty()
    try:
        result = run_with(ctx, subprocess.DEVNULL, slave)
    finally:
        os.close(slave)
        os.close(master)
    assert result.returncode == 1
    assert b"stdin and stdout must both be a terminal" in result.stderr
    assert b"NOT issued" in result.stderr
    assert not ctx.log.exists()  # nothing generated
    assert list(ctx.work.iterdir()) == []


def test_refuses_stdout_that_isnt_a_terminal(ctx):
    master, slave = os.openpty()
    try:
        result = run_with(ctx, slave, subprocess.PIPE)
    finally:
        os.close(slave)
        os.close(master)
    assert result.returncode == 1
    assert b"stdin and stdout must both be a terminal" in result.stderr
    assert not ctx.log.exists()


def test_refuses_to_run_inside_claude_code(ctx):
    term = Term(ctx.args, {**ctx.env, "CLAUDECODE": "1"})
    assert term.finish() == 1
    assert b"refusing to run inside Claude Code" in term.out
    assert ALT_ON not in term.out
    assert not ctx.log.exists()


def test_refuses_a_work_directory_on_disk(ctx):
    fstype = subprocess.run(
        ["stat", "-f", "-c", "%T", str(ctx.work)], capture_output=True, text=True, check=True
    ).stdout
    if fstype.strip() in ("tmpfs", "ramfs"):
        pytest.skip("the test directory is on tmpfs")
    term = Term(["--name", "operator", "--work-dir", str(ctx.work)], ctx.env)
    assert term.finish() == 1
    assert b"not tmpfs" in term.out
    assert b"--allow-disk-work-dir" in term.out
    assert not ctx.log.exists()


@pytest.mark.parametrize(
    ("args", "message"),
    [
        ([], b"--name is required"),
        (["--name", "admin"], b"--name must be operator or recovery"),
        (["--name", "operator", "--retain-days", "a year"], b"must be a whole number of days"),
        (["--name"], b"--name needs a value"),
        (["--name", "operator", "--bogus"], b"unknown argument: --bogus"),
    ],
)
def test_usage_errors_exit_2(ctx, args, message):
    term = Term(args, ctx.env)
    assert term.finish() == 2
    assert message in term.out


# --- Hardening -------------------------------------------------------------


@pytest.mark.skipif(os.geteuid() == 0, reason="root can read a non-dumpable process")
def test_the_process_is_hardened_and_the_key_is_not_in_its_arguments(ctx):
    term = Term(ctx.args, ctx.env)
    _, secret = shown(term)
    proc = Path(f"/proc/{term.pid}")
    assert re.search(r"Max core file size\s+0\s+0", (proc / "limits").read_text())
    # Non-dumpable: its /proc files belong to root, so its environment
    # and memory can't be read by this (same) user.
    with pytest.raises(PermissionError):
        (proc / "environ").read_bytes()
    with pytest.raises(PermissionError):
        (proc / "mem").open("rb")
    assert secret.encode() not in (proc / "cmdline").read_bytes()
    term.send("\n")
    term.expect(PROMPT)
    term.send(secret + "\n")
    assert term.finish() == 0
    assert_clean(ctx, term, secret)


# --- Interrupted at each stage ---------------------------------------------


def reach(stage, term, ctx):
    """Drive the script to a stage; the private key, once shown."""
    if stage == "generating":
        marker = Path(ctx.env["SLOW_KEYGEN"])
        deadline = time.monotonic() + 20
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        assert marker.exists()
        return None
    _, secret = shown(term)
    if stage == "shown":
        return secret
    term.send("\n")
    term.expect(PROMPT)
    if stage == "pasting":
        return secret
    term.send("wrong\n")
    term.expect(AGAIN)
    if stage == "asked to show again":
        return secret
    term.send("y\n")
    shown(term)
    return secret  # "shown again"


@pytest.mark.parametrize("signum", [signal.SIGINT, signal.SIGTERM], ids=["SIGINT", "SIGTERM"])
@pytest.mark.parametrize("stage", ["generating", "shown", "pasting", "asked to show again", "shown again"])
def test_interrupted_it_issues_nothing_and_cleans_up(ctx, stage, signum):
    if stage == "generating":
        ctx.env["SLOW_KEYGEN"] = str(ctx.tmp / "generating")
    term = Term(ctx.args, ctx.env)
    secret = reach(stage, term, ctx)
    os.kill(term.pid, signum)
    assert term.finish() == 130
    normal = term.normal_screen()
    assert b"interrupted" in normal
    assert b"the operator key was NOT issued" in normal
    assert b"is issued" not in normal
    assert_clean(ctx, term, secret)


def test_ctrl_c_at_the_paste_prompt(ctx):
    term = Term(ctx.args, ctx.env)
    _, secret = shown(term)
    term.send("\n")
    term.expect(PROMPT)
    term.send("\x03")  # the terminal turns it into SIGINT
    assert term.finish() == 130
    assert b"NOT issued" in term.out
    assert_clean(ctx, term, secret)


# --- Cleanup failure -------------------------------------------------------


def test_a_work_directory_that_cant_be_removed_exits_3_and_names_it(ctx):
    term = Term(ctx.args, ctx.env)
    _, secret = shown(term)
    (work,) = ctx.work.iterdir()
    ctx.work.chmod(0o500)  # the work directory can't be removed from here
    try:
        term.send("\n")
        term.expect(PROMPT)
        term.send(secret + "\n")
        assert term.finish() == 3
    finally:
        ctx.work.chmod(0o700)
    assert b"is issued" in term.out
    assert f"CLEANUP FAILED: could not remove the work directory {work}".encode() in term.out
    assert b"shred -u" in term.out
    assert list(work.iterdir()) == []  # its files were still overwritten and removed
    work.rmdir()
    assert_clean(ctx, term, secret)

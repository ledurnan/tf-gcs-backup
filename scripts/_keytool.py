"""What issue-key and issue-age-key share: a private work directory in RAM
that is shredded on exit, error reporting, signal handling, the undo, and
the exit codes.

A script sets its name with set_prog(), subclasses Job, and returns
run_job(job) as its exit status.
"""

import os
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_USAGE = 2
# The undo or the cleanup failed: the message says what is left to do.
EXIT_CLEANUP_FAILED = 3
EXIT_INTERRUPTED = 130

SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)

_prog = "keytool"


def set_prog(name):
    global _prog
    _prog = name


def prog():
    return _prog


class Usage(Exception):
    """A usage error: exit 2, before anything is touched."""


class Failed(Exception):
    """A check or step failed. The message, then indented detail lines."""

    def __init__(self, message, *details):
        super().__init__(message)
        self.details = [line for d in details for line in str(d).splitlines() if line.strip()]


class Interrupted(Exception):
    """SIGINT, SIGTERM or SIGHUP."""


def info(message):
    print(f"{_prog}: {message}", flush=True)


def warn(message):
    print(f"{_prog}: {message}", file=sys.stderr, flush=True)


def detail(text):
    """Lines under a warning: indented, without the prefix."""
    print(text, file=sys.stderr, flush=True)


def usage_error(e):
    warn(str(e))
    detail(f"Run {_prog} --help for usage.")
    return EXIT_USAGE


def need_tools(*tools):
    for tool in tools:
        if not shutil.which(tool):
            raise Failed(f"{tool} is not installed or not on PATH")


def prefixed(prefix, *texts):
    return "\n".join(f"{prefix}{line}" for text in texts for line in text.splitlines() if line.strip())


# --- Signals ---------------------------------------------------------------

# A signal while a command runs is acted on once the command returns, as a
# shell trap would be: killing gcloud part-way through issuing a key could
# leave a key Google created after the undo looked for it. Ctrl-C reaches
# the command too, so that rarely waits long.
_in_command = False
_pending_signal = None


def _on_signal(signum, _frame):
    global _pending_signal
    if _in_command:
        _pending_signal = signum
        return
    raise Interrupted


def _check_signal():
    global _pending_signal
    if _pending_signal is not None:
        _pending_signal = None
        raise Interrupted


def _on_signal_while_finishing(_signum, _frame):
    # Undoing or cleaning up already: finish it. A command it runs has the
    # signal too, and if that makes it fail the undo reports what is left.
    warn("interrupted again; still cleaning up")


def run(cmd, *, input=None, text=True):  # noqa: A002 - subprocess's name
    """Run a command with its output captured, and no stdin unless input
    is given."""
    global _in_command
    stdin = {"input": input} if input is not None else {"stdin": subprocess.DEVNULL}
    _in_command = True
    try:
        return subprocess.run(cmd, capture_output=True, text=text, check=False, **stdin)
    finally:
        _in_command = False
        _check_signal()


# --- The work directory ----------------------------------------------------


class WorkDir:
    """A private directory for plaintext, in RAM unless allowed otherwise.
    parent defaults to $XDG_RUNTIME_DIR, else /dev/shm."""

    def __init__(self, parent, allow_disk):
        need_tools("stat")
        parent = parent or os.environ.get("XDG_RUNTIME_DIR") or "/dev/shm"
        if not (os.path.isdir(parent) and os.access(parent, os.W_OK)):
            raise Failed(f"work directory {parent} doesn't exist or isn't writable", "Choose one with --work-dir.")
        fstype = run(["stat", "-f", "-c", "%T", parent]).stdout.strip()
        if fstype not in ("tmpfs", "ramfs") and not allow_disk:
            raise Failed(
                f"work directory {parent} is on {fstype}, not tmpfs: the key would be written to a disk",
                "Point --work-dir at a tmpfs ($XDG_RUNTIME_DIR, /dev/shm), or pass --allow-disk-work-dir to accept it.",
            )
        try:
            self.path = Path(tempfile.mkdtemp(prefix=f"{_prog}.", dir=parent))
        except OSError:
            raise Failed(f"could not create a work directory in {parent}") from None
        self.path.chmod(0o700)

    def __truediv__(self, name):
        return self.path / name

    def scrub(self):
        """Remove every file without leaving its contents behind. On tmpfs
        overwriting adds little, but it is cheap and holds if the work
        directory was allowed onto a disk. False if anything is left."""
        if not self.path.exists():
            return True
        for root, _dirs, files in os.walk(self.path):
            for name in files:
                path = os.path.join(root, name)
                try:
                    size = os.path.getsize(path)
                    with open(path, "r+b") as f:
                        f.write(os.urandom(size))
                        f.flush()
                        os.fsync(f.fileno())
                except OSError:
                    pass
        shutil.rmtree(self.path, ignore_errors=True)
        return not self.path.exists()


# --- Running a job ---------------------------------------------------------


class Job:
    """What run_job runs. main() does the work; undo() reverses what an
    unfinished run changed outside the work directory."""

    work = None  # a WorkDir, once main() has made one
    interrupted = False

    def main(self):
        raise NotImplementedError

    def needs_undo(self):
        return False

    def undo(self):
        """True if everything was put back; otherwise what is left has
        been printed."""
        return True

    def on_failure(self):
        """Called after a failed or interrupted run, after any undo."""


def run_job(job):
    """Run job.main(), undo and clean up after it, and return the exit
    status."""
    os.umask(0o077)
    for signum in SIGNALS:
        signal.signal(signum, _on_signal)
    rc = EXIT_OK
    try:
        job.main()
    except Failed as e:
        warn(f"ERROR: {e}")
        for line in e.details:
            detail(f"  {line}")
        rc = EXIT_FAILED
    except Interrupted:
        warn("interrupted")
        job.interrupted = True
        rc = EXIT_INTERRUPTED
    except Exception as e:  # noqa: BLE001 - anything unforeseen still undoes
        warn(f"ERROR: unexpected {type(e).__name__}: {e}")
        rc = EXIT_FAILED
    finally:
        for signum in SIGNALS:
            signal.signal(signum, _on_signal_while_finishing)
        rc = _finish(job, rc)
    return rc


def _finish(job, rc):
    undone = True
    if rc != EXIT_OK and job.needs_undo():
        warn("the run did not finish; undoing what it changed")
        try:
            undone = job.undo()
        except Exception as e:  # noqa: BLE001 - report, then exit 3
            warn(f"UNDO FAILED: unexpected {type(e).__name__}: {e}")
            undone = False
    if rc != EXIT_OK:
        job.on_failure()
    scrubbed = job.work is None or job.work.scrub()
    if not scrubbed:
        path = job.work.path
        warn(f"CLEANUP FAILED: could not remove the work directory {path}, which may hold a plaintext key.")
        detail(f"  Shred it by hand: find {path} -type f -exec shred -u {{}} + && rm -rf {path}")
    if not undone:
        warn("FAILED, AND THE UNDO FAILED: see above.")
    if not (undone and scrubbed):
        return EXIT_CLEANUP_FAILED
    return rc

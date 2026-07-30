# agents/release/critic-queue-lib.sh — shared enqueue for the shoulder-mode
# capture hooks. Sourced by the per-harness front-ends:
#   critic-queue.sh        (claude PostToolUse)
#   critic-queue-codex.sh  (codex  PostToolUse — apply_patch V4A patches)
#   critic-queue-hermes.sh (hermes post_tool_call — write_file/patch/edit_file)
#
# Each front-end parses ITS harness's payload down to (file_path, session_id,
# project_dir) and calls cq_enqueue. This file owns the filters + the queue
# file format that agents/release/critic-watch.sh drains — keep that format
# byte-stable (`<file_path> <epoch>` per line, one file per line).
#
# cq_enqueue stores file_path EXACTLY as handed to it (no relative→absolute
# rewrite) so the claude path stays byte-identical to its pre-refactor
# behavior; a front-end that wants a path normalized must do so before calling.
# ALWAYS returns 0 — a capture hook must never fail the dev agent's tool loop.

# Queue mutation uses a portable mkdir lock because capture hooks and the
# long-lived watcher are separate processes. The owner token prevents an old
# process from removing a successor's lock; a dead owner is renamed out of the
# lock path before cleanup. Queue contents remain byte-for-byte unchanged.
CQ_LOCK_DIR=""
CQ_LOCK_TOKEN=""
CQ_LOCK_PID=""
CQ_REAP_CLAIM_GENERATION=""
CQ_REAP_CLAIM_LOCK=""
CQ_REAP_CLAIM_PID=""
CQ_REAP_CLAIM_TOKEN=""
CQ_REAP_CLAIM_IDENTITY=""
CQ_LAST_ERROR=""
CQ_PROCESS_IDENTITY_HELPER="$(
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
)/critic-process-identity.py"
_CQ_LOCK_WAIT_STEPS_RAW="${CQ_LOCK_WAIT_STEPS:-200}"
case "$_CQ_LOCK_WAIT_STEPS_RAW" in
  ''|*[!0-9]*) CQ_LOCK_WAIT_STEPS=200 ;;
  *)
    _CQ_LOCK_WAIT_STEPS_DEC="$_CQ_LOCK_WAIT_STEPS_RAW"
    while [ "${_CQ_LOCK_WAIT_STEPS_DEC#0}" != \
        "$_CQ_LOCK_WAIT_STEPS_DEC" ]; do
      _CQ_LOCK_WAIT_STEPS_DEC="${_CQ_LOCK_WAIT_STEPS_DEC#0}"
    done
    [ -n "$_CQ_LOCK_WAIT_STEPS_DEC" ] || _CQ_LOCK_WAIT_STEPS_DEC=0
    if [ "$_CQ_LOCK_WAIT_STEPS_DEC" -gt 0 ] &&
        [ "${#_CQ_LOCK_WAIT_STEPS_DEC}" -le 5 ] &&
        [ "$_CQ_LOCK_WAIT_STEPS_DEC" -le 10000 ] 2>/dev/null; then
      CQ_LOCK_WAIT_STEPS="$_CQ_LOCK_WAIT_STEPS_DEC"
    else
      CQ_LOCK_WAIT_STEPS=200
    fi
    ;;
esac
unset _CQ_LOCK_WAIT_STEPS_RAW _CQ_LOCK_WAIT_STEPS_DEC
_CQ_REAP_GRACE_RAW="${CQ_REAP_GRACE_SEC:-1}"
case "$_CQ_REAP_GRACE_RAW" in
  ''|*[!0-9]*) CQ_REAP_GRACE_SEC=1 ;;
  *)
    _CQ_REAP_GRACE_DEC="$_CQ_REAP_GRACE_RAW"
    while [ "${_CQ_REAP_GRACE_DEC#0}" != "$_CQ_REAP_GRACE_DEC" ]; do
      _CQ_REAP_GRACE_DEC="${_CQ_REAP_GRACE_DEC#0}"
    done
    [ -n "$_CQ_REAP_GRACE_DEC" ] || _CQ_REAP_GRACE_DEC=0
    if [ "${#_CQ_REAP_GRACE_DEC}" -le 2 ] &&
        [ "$_CQ_REAP_GRACE_DEC" -le 30 ] 2>/dev/null; then
      CQ_REAP_GRACE_SEC="$_CQ_REAP_GRACE_DEC"
    else
      CQ_REAP_GRACE_SEC=1
    fi
    ;;
esac
unset _CQ_REAP_GRACE_RAW _CQ_REAP_GRACE_DEC

_cq_mtime() {
  stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null
}

_cq_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

_cq_uid() {
  stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1" 2>/dev/null
}

_cq_size() {
  stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null
}

_cq_nlink() {
  stat -c '%h' "$1" 2>/dev/null || stat -f '%l' "$1" 2>/dev/null
}

_cq_process_identity() {
  python3 "$CQ_PROCESS_IDENTITY_HELPER" "$1"
}

_cq_current_shell_pid() {
  local pid_file rc
  if [[ "${BASHPID:-}" =~ ^[1-9][0-9]*$ ]]; then
    CQ_CURRENT_SHELL_PID="$BASHPID"
    return 0
  fi
  # Stock macOS Bash 3.2 predates BASHPID. Run Python as a foreground child so
  # its PPID is the actual calling shell, including a background subshell where
  # Bash's inherited $$ is wrong. Capturing stdout would add a short-lived
  # command-substitution process and record that disposable PID instead.
  pid_file="$(umask 077; mktemp \
    "${TMPDIR:-/tmp}/shipyard-critic-shell-pid.XXXXXX")" || return 1
  python3 - "$pid_file" <<'PY'
import os
from pathlib import Path
import sys

Path(sys.argv[1]).write_text(f"{os.getppid()}\n", encoding="ascii")
PY
  rc=$?
  if [ "$rc" -eq 0 ]; then
    IFS= read -r CQ_CURRENT_SHELL_PID <"$pid_file" || rc=1
  fi
  rm -f -- "$pid_file"
  [ "$rc" -eq 0 ] || return 1
  [[ "$CQ_CURRENT_SHELL_PID" =~ ^[1-9][0-9]*$ ]]
}

_cq_require_lock_capabilities() {
  local capability
  for capability in python3; do
    if ! command -v "$capability" >/dev/null 2>&1; then
      printf 'critic-queue: required lock capability unavailable: %s\n' \
        "$capability" >&2
      return 1
    fi
  done
  if [ ! -f "$CQ_PROCESS_IDENTITY_HELPER" ]; then
    printf 'critic-queue: required lock capability unavailable: process identity helper\n' >&2
    return 1
  fi
}

_cq_lock_tree() {
  # _cq_lock_tree <validate|delete> <path> <owner|recovery>
  # Only Shipyard's two exact lock schemas are ever removable. No recursive
  # cleanup is used: an unexpected entry preserves the complete tree for
  # inspection instead of turning a colliding *.lock directory into data loss.
  python3 - "$1" "$2" "$3" <<'PY'
import os
import stat
import sys

action, path, shape = sys.argv[1:]
path = os.path.abspath(path)
parent = os.path.dirname(path)
name = os.path.basename(path)
dir_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
dir_flags |= getattr(os, "O_DIRECTORY", 0)
dir_flags |= getattr(os, "O_NOFOLLOW", 0)
owner_flags = os.O_RDONLY | os.O_NONBLOCK
owner_flags |= getattr(os, "O_CLOEXEC", 0)
owner_flags |= getattr(os, "O_NOFOLLOW", 0)


def private_dir(fd):
    item = os.fstat(fd)
    return (
        item.st_uid == os.getuid()
        and stat.S_IMODE(item.st_mode) == 0o700
    )


def private_owner(directory_fd, owner_name):
    fd = os.open(owner_name, owner_flags, dir_fd=directory_fd)
    try:
        item = os.fstat(fd)
        return (
            stat.S_ISREG(item.st_mode)
            and item.st_uid == os.getuid()
            and stat.S_IMODE(item.st_mode) == 0o600
            and item.st_nlink == 1
            and item.st_size <= 4096
        )
    finally:
        os.close(fd)


def bounded_leaf(directory_fd, entry_name):
    item = os.stat(entry_name, dir_fd=directory_fd, follow_symlinks=False)
    return not stat.S_ISDIR(item.st_mode)


parent_fd = None
tree_fd = None
reap_fd = None
try:
    if action not in ("validate", "delete"):
        raise SystemExit(2)
    if shape not in ("owner", "recovery"):
        raise SystemExit(2)
    parent_fd = os.open(parent, dir_flags)
    tree_fd = os.open(name, dir_flags, dir_fd=parent_fd)
    if not private_dir(tree_fd):
        raise SystemExit(1)

    entries = sorted(os.listdir(tree_fd))
    if shape == "owner":
        if entries != ["owner"] or not private_owner(tree_fd, "owner"):
            raise SystemExit(1)
    else:
        if entries not in ([".reap"], [".reap", "owner"]):
            raise SystemExit(1)
        # A crashed publisher can leave a malformed regular file, FIFO, or
        # symlink at outer owner. Unlinking one non-directory entry never
        # follows it or deletes its target; a directory is an unbounded tree
        # and is therefore preserved.
        if "owner" in entries and not bounded_leaf(tree_fd, "owner"):
            raise SystemExit(1)
        reap_fd = os.open(".reap", dir_flags, dir_fd=tree_fd)
        if (
            not private_dir(reap_fd)
            or os.listdir(reap_fd) != ["owner"]
            or not private_owner(reap_fd, "owner")
        ):
            raise SystemExit(1)

    if action == "delete":
        if reap_fd is not None:
            os.unlink("owner", dir_fd=reap_fd)
            os.close(reap_fd)
            reap_fd = None
            os.rmdir(".reap", dir_fd=tree_fd)
        if "owner" in entries:
            os.unlink("owner", dir_fd=tree_fd)
        os.close(tree_fd)
        tree_fd = None
        os.rmdir(name, dir_fd=parent_fd)
except SystemExit:
    raise
except OSError:
    raise SystemExit(1)
finally:
    for fd in (reap_fd, tree_fd, parent_fd):
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
PY
}

_cq_retire_directory() {
  # Never hand mv a destination that can already be a directory: POSIX mv
  # would nest the source and a following recursive cleanup could erase
  # unrelated contents. An exclusive private container makes `item` absent by
  # construction, and cleanup is confined to that exact container.
  local source="$1" shape="$2" parent container
  _cq_lock_tree validate "$source" "$shape" || return 1
  parent="${source%/*}"
  [ "$parent" != "$source" ] || parent="."
  container="$(
    umask 077
    mktemp -d "$parent/.critic-retire.XXXXXXXX"
  )" || return 1
  [ -d "$container" ] && [ ! -L "$container" ] &&
    [ "$(_cq_uid "$container" || true)" = "$(id -u)" ] &&
    [ "$(_cq_mode "$container" || true)" = "700" ] &&
    [ ! -e "$container/item" ] && [ ! -L "$container/item" ] || {
      rmdir "$container" 2>/dev/null || true
      return 1
    }
  if mv "$source" "$container/item" 2>/dev/null; then
    if _cq_lock_tree delete "$container/item" "$shape" &&
        rmdir "$container" 2>/dev/null; then
      return 0
    fi
    # The private retirement container intentionally remains when its contents
    # no longer match Shipyard's schema. Preserving bytes beats recursive loss.
    return 1
  fi
  rmdir "$container" 2>/dev/null || true
  return 1
}

_cq_lock_owner() {
  [ -f "$1/owner" ] || return 1
  CQ_OWNER_IDENTITY=""
  IFS=' ' read -r CQ_OWNER_PID CQ_OWNER_TOKEN CQ_OWNER_IDENTITY \
    <"$1/owner" || return 1
  [[ "$CQ_OWNER_PID" =~ ^[0-9]+$ ]] && [ -n "$CQ_OWNER_TOKEN" ]
}

_cq_owner_is_stale() {
  local current_identity
  if ! kill -0 "$CQ_OWNER_PID" 2>/dev/null; then
    return 0
  fi
  # Legacy owners without a process-start identity, and transient identity
  # lookup failures, are conservatively live. A PID is stale only when its
  # current process-start identity positively differs from the recorded one.
  [ -n "$CQ_OWNER_IDENTITY" ] || return 1
  current_identity="$(_cq_process_identity "$CQ_OWNER_PID" || true)"
  [ -n "$current_identity" ] || return 1
  [ "$current_identity" != "$CQ_OWNER_IDENTITY" ]
}

_cq_outer_lock_reap_probe() {
  # pre: print the exact directory generation only when it is eligible for
  # recovery. post: revalidate that generation after .reap publication and
  # refuse recovery if a valid live owner appeared during the handoff.
  #
  # The owner is opened nonblocking and without following symlinks. Python is
  # used here because portable shell stat/read cannot safely inspect a FIFO or
  # pin an inode generation across the two claim phases.
  python3 - "$1" "$2" "${3:-}" "${4:-}" "${5:-}" "${6:-}" \
    "${7:-}" \
    "$CQ_PROCESS_IDENTITY_HELPER" <<'PY'
import os
import re
import stat
import subprocess
import sys
import time

(
    lock,
    phase,
    expected,
    expected_pid,
    expected_token,
    expected_identity,
    expected_claim,
    identity_helper,
) = sys.argv[1:]


def process_identity(pid):
    try:
        result = subprocess.run(
            [sys.executable, identity_helper, str(pid)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        identity = result.stdout.strip()
        if re.fullmatch(r"[0-9]+-[0-9]+", identity) is None:
            return None
        return identity
    except (OSError, subprocess.SubprocessError):
        return None


def pid_is_live(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def read_owner(lock_fd):
    flags = os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        owner_fd = os.open("owner", flags, dir_fd=lock_fd)
    except OSError:
        return None
    try:
        owner_stat = os.fstat(owner_fd)
        if (
            not stat.S_ISREG(owner_stat.st_mode)
            or owner_stat.st_uid != os.getuid()
            or stat.S_IMODE(owner_stat.st_mode) != 0o600
            or owner_stat.st_nlink != 1
            or owner_stat.st_size > 4096
        ):
            return None
        data = os.read(owner_fd, 4097).decode("ascii")
    except (OSError, UnicodeError):
        return None
    finally:
        os.close(owner_fd)

    exact = re.fullmatch(
        r"([1-9][0-9]*) ([^ \n]+) ([^ \n]+)\n",
        data,
    )
    if exact is not None:
        return int(exact.group(1)), exact.group(2), exact.group(3)

    # Older two-field owners had no process-start identity. Preserve their
    # conservative live-PID behavior while still treating dead records stale.
    legacy = re.fullmatch(r"([1-9][0-9]*) ([^ \n]+)\n", data)
    if legacy is not None:
        return int(legacy.group(1)), legacy.group(2), None
    return None


def owner_is_live(owner):
    if owner is None:
        return False
    pid, _token, identity = owner
    if not pid_is_live(pid):
        return False
    if identity is None:
        return True
    current = process_identity(pid)
    return current is None or current == identity


def safe_owner_entry(directory_fd, expected_data=None):
    owner_flags = os.O_RDONLY | os.O_NONBLOCK
    owner_flags |= getattr(os, "O_CLOEXEC", 0)
    owner_flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        owner_fd = os.open("owner", owner_flags, dir_fd=directory_fd)
    except OSError:
        return False
    try:
        item = os.fstat(owner_fd)
        if (
            not stat.S_ISREG(item.st_mode)
            or item.st_uid != os.getuid()
            or stat.S_IMODE(item.st_mode) != 0o600
            or item.st_nlink != 1
            or item.st_size > 4096
        ):
            return False
        data = os.read(owner_fd, 4097)
        return expected_data is None or data == expected_data
    except OSError:
        return False
    finally:
        os.close(owner_fd)


def bounded_leaf_entry(directory_fd, entry_name):
    try:
        item = os.stat(
            entry_name, dir_fd=directory_fd, follow_symlinks=False
        )
        return not stat.S_ISDIR(item.st_mode)
    except OSError:
        return False


def bounded_recovery_tree(lock_fd):
    entries = sorted(os.listdir(lock_fd))
    if entries not in ([".reap"], [".reap", "owner"]):
        return False
    if "owner" in entries and not bounded_leaf_entry(lock_fd, "owner"):
        return False
    try:
        claim_fd = os.open(".reap", flags, dir_fd=lock_fd)
    except OSError:
        return False
    try:
        claim = os.fstat(claim_fd)
        claim_generation = f"{claim.st_dev}:{claim.st_ino}"
        expected_data = (
            f"{expected_pid} {expected_token} {expected_identity}\n"
        ).encode("ascii")
        return (
            claim.st_uid == os.getuid()
            and stat.S_IMODE(claim.st_mode) == 0o700
            and claim_generation == expected_claim
            and os.listdir(claim_fd) == ["owner"]
            and safe_owner_entry(claim_fd, expected_data)
        )
    finally:
        os.close(claim_fd)


flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
flags |= getattr(os, "O_DIRECTORY", 0)
flags |= getattr(os, "O_NOFOLLOW", 0)
try:
    lock_fd = os.open(lock, flags)
    try:
        lock_stat = os.fstat(lock_fd)
        if (
            lock_stat.st_uid != os.getuid()
            or stat.S_IMODE(lock_stat.st_mode) != 0o700
        ):
            raise SystemExit(1)
        generation = f"{lock_stat.st_dev}:{lock_stat.st_ino}"
        owner = read_owner(lock_fd)
        if phase == "generation":
            print(generation)
        elif phase == "pre":
            if owner is not None:
                if owner_is_live(owner):
                    raise SystemExit(1)
            else:
                age = time.time() - lock_stat.st_mtime
                if age < 30 and age >= -30:
                    raise SystemExit(1)
            print(generation)
        elif phase == "post":
            if (
                generation != expected
                or owner_is_live(owner)
                or not bounded_recovery_tree(lock_fd)
            ):
                raise SystemExit(1)
        elif phase == "owned":
            try:
                os.stat(".reap", dir_fd=lock_fd, follow_symlinks=False)
                claim_present = True
            except FileNotFoundError:
                claim_present = False
            if (
                generation != expected
                or claim_present
                or owner
                != (
                    int(expected_pid),
                    expected_token,
                    expected_identity,
                )
            ):
                raise SystemExit(1)
        else:
            raise SystemExit(2)
    finally:
        os.close(lock_fd)
except SystemExit:
    raise
except (OSError, ValueError):
    raise SystemExit(2)
PY
}

_cq_outer_lock_create() {
  # The coordination mutex is acquired before mkdir, so a busy/frozen reaper
  # can never make us leave an ownerless directory behind. Creation, owner
  # publication, and generation verification all use pinned directory fds.
  python3 - outer-lock-create "$1" "$2" "$3" "$4" <<'PY'
import os
import errno
import fcntl
import stat
import sys
import time

_tag, lock, pid, token, identity = sys.argv[1:]
expected_data = f"{pid} {token} {identity}\n".encode("ascii")
lock = os.path.abspath(lock)
parent = os.path.dirname(lock)
lock_name = os.path.basename(lock)
# Two fixed coordination files bound persistent state per queue directory while
# still serializing every owner publication. Queue critical sections are tiny.
mutex_path = os.path.join(parent, ".critic-owner-mutex")
dir_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
dir_flags |= getattr(os, "O_DIRECTORY", 0)
dir_flags |= getattr(os, "O_NOFOLLOW", 0)
owner_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
owner_flags |= getattr(os, "O_CLOEXEC", 0)
owner_flags |= getattr(os, "O_NOFOLLOW", 0)
test_pause_limit_sec = 2.0


def generation(item):
    return f"{item.st_dev}:{item.st_ino}"


def bounded_test_pause(path_env, label):
    pause = os.environ.get(path_env)
    if not pause:
        return
    print(f"critic-queue-test:{label}", file=sys.stderr, flush=True)
    deadline = time.monotonic() + test_pause_limit_sec
    while os.path.exists(pause) and time.monotonic() < deadline:
        time.sleep(0.01)


parent_fd = None
lock_fd = None
mutex_fd = None
created_generation = None
try:
    mutex_flags = os.O_RDWR | os.O_NONBLOCK
    mutex_flags |= getattr(os, "O_CLOEXEC", 0)
    mutex_flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        mutex_fd = os.open(
            mutex_path, mutex_flags | os.O_CREAT | os.O_EXCL, 0o600
        )
        os.fchmod(mutex_fd, 0o600)
    except FileExistsError:
        mutex_fd = os.open(mutex_path, mutex_flags)
    mutex_stat = os.fstat(mutex_fd)
    if (
        not stat.S_ISREG(mutex_stat.st_mode)
        or mutex_stat.st_uid != os.getuid()
        or stat.S_IMODE(mutex_stat.st_mode) != 0o600
        or mutex_stat.st_nlink != 1
    ):
        raise OSError("owner coordination mutex is unsafe")
    try:
        fcntl.flock(mutex_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        if exc.errno in (errno.EACCES, errno.EAGAIN):
            raise SystemExit(1)
        raise
    parent_fd = os.open(parent, dir_flags)
    old_umask = os.umask(0o077)
    try:
        os.mkdir(lock_name, 0o700, dir_fd=parent_fd)
    finally:
        os.umask(old_umask)
    lock_fd = os.open(lock_name, dir_flags, dir_fd=parent_fd)
    try:
        os.fchmod(lock_fd, 0o700)
        lock_stat = os.fstat(lock_fd)
        created_generation = generation(lock_stat)
        if (
            lock_stat.st_uid != os.getuid()
            or stat.S_IMODE(lock_stat.st_mode) != 0o700
        ):
            raise SystemExit(1)
        bounded_test_pause(
            "CQ_QUEUE_TEST_OUTER_CREATE_PAUSE", "outer-created"
        )
        owner_fd = os.open("owner", owner_flags, 0o600, dir_fd=lock_fd)
        try:
            os.fchmod(owner_fd, 0o600)
            written = 0
            while written < len(expected_data):
                count = os.write(owner_fd, expected_data[written:])
                if count <= 0:
                    raise OSError("short owner write")
                written += count
            owner_stat = os.fstat(owner_fd)
            if (
                not stat.S_ISREG(owner_stat.st_mode)
                or owner_stat.st_uid != os.getuid()
                or stat.S_IMODE(owner_stat.st_mode) != 0o600
                or owner_stat.st_nlink != 1
                or owner_stat.st_size != len(expected_data)
            ):
                raise SystemExit(1)
        finally:
            os.close(owner_fd)
        installed = os.stat(lock, follow_symlinks=False)
        publish_error = generation(installed) != created_generation
        bounded_test_pause(
            "CQ_QUEUE_TEST_OUTER_CREATE_OBSERVE_PAUSE",
            "outer-attempted",
        )
        if publish_error:
            raise SystemExit(1)
        print(created_generation)
    except BaseException:
        # Clean only if the public pathname still names our exact generation.
        # A test or stale handoff may have moved it and installed a successor.
        try:
            current = os.stat(
                lock_name, dir_fd=parent_fd, follow_symlinks=False
            )
            same_generation = (
                created_generation is not None
                and generation(current) == created_generation
            )
        except OSError:
            same_generation = False
        if same_generation:
            try:
                os.unlink("owner", dir_fd=lock_fd)
            except OSError:
                pass
            try:
                os.rmdir(lock_name, dir_fd=parent_fd)
            except OSError:
                pass
        raise
except SystemExit:
    raise
except (OSError, UnicodeError, ValueError):
    raise SystemExit(2)
finally:
    for fd in (lock_fd, parent_fd, mutex_fd):
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
PY
}

_cq_reap_marker_is_strictly_live() {
  local parsed pid identity current
  parsed="$(python3 - "$1" <<'PY'
import os
import re
import stat
import sys

marker = sys.argv[1]
dir_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
dir_flags |= getattr(os, "O_DIRECTORY", 0)
dir_flags |= getattr(os, "O_NOFOLLOW", 0)
owner_flags = os.O_RDONLY | os.O_NONBLOCK
owner_flags |= getattr(os, "O_CLOEXEC", 0)
owner_flags |= getattr(os, "O_NOFOLLOW", 0)

try:
    marker_fd = os.open(marker, dir_flags)
    try:
        marker_stat = os.fstat(marker_fd)
        if (
            marker_stat.st_uid != os.getuid()
            or stat.S_IMODE(marker_stat.st_mode) != 0o700
        ):
            raise SystemExit(1)
        owner_fd = os.open("owner", owner_flags, dir_fd=marker_fd)
        try:
            owner_stat = os.fstat(owner_fd)
            if (
                not stat.S_ISREG(owner_stat.st_mode)
                or owner_stat.st_uid != os.getuid()
                or stat.S_IMODE(owner_stat.st_mode) != 0o600
                or owner_stat.st_nlink != 1
                or owner_stat.st_size > 4096
            ):
                raise SystemExit(1)
            data = os.read(owner_fd, 4097).decode("ascii")
        finally:
            os.close(owner_fd)
    finally:
        os.close(marker_fd)
    match = re.fullmatch(
        r"([1-9][0-9]*) ([0-9]+-[0-9]+-[0-9]+) "
        r"([0-9]+-[0-9]+)\n",
        data,
    )
    if match is None:
        raise SystemExit(1)
    print(match.group(1), match.group(3))
except SystemExit:
    raise
except (OSError, UnicodeError, ValueError):
    raise SystemExit(2)
PY
  )" || return 1
  IFS=' ' read -r pid identity <<<"$parsed" || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  current="$(_cq_process_identity "$pid" || true)"
  [ -n "$current" ] && [ "$current" = "$identity" ]
}

_cq_reap_claim_probe() {
  python3 - "$1" "$2" "${3:-}" "${4:-}" "${5:-}" "${6:-}" <<'PY'
import os
import stat
import sys

lock, phase, expected, expected_pid, expected_token, expected_identity = (
    sys.argv[1:]
)
dir_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
dir_flags |= getattr(os, "O_DIRECTORY", 0)
dir_flags |= getattr(os, "O_NOFOLLOW", 0)
owner_flags = os.O_RDONLY | os.O_NONBLOCK
owner_flags |= getattr(os, "O_CLOEXEC", 0)
owner_flags |= getattr(os, "O_NOFOLLOW", 0)

try:
    lock_fd = os.open(lock, dir_flags)
    try:
        claim_fd = os.open(".reap", dir_flags, dir_fd=lock_fd)
        try:
            claim_stat = os.fstat(claim_fd)
            generation = f"{claim_stat.st_dev}:{claim_stat.st_ino}"
            if (
                claim_stat.st_uid != os.getuid()
                or stat.S_IMODE(claim_stat.st_mode) != 0o700
            ):
                raise SystemExit(1)
            if phase == "generation":
                print(generation)
                raise SystemExit(0)
            if phase != "owned" or generation != expected:
                raise SystemExit(1)

            owner_fd = os.open("owner", owner_flags, dir_fd=claim_fd)
            try:
                owner_stat = os.fstat(owner_fd)
                expected_data = (
                    f"{expected_pid} {expected_token} "
                    f"{expected_identity}\n"
                ).encode("ascii")
                if (
                    not stat.S_ISREG(owner_stat.st_mode)
                    or owner_stat.st_uid != os.getuid()
                    or stat.S_IMODE(owner_stat.st_mode) != 0o600
                    or owner_stat.st_nlink != 1
                    or owner_stat.st_size != len(expected_data)
                    or os.read(owner_fd, len(expected_data) + 1)
                    != expected_data
                ):
                    raise SystemExit(1)
            finally:
                os.close(owner_fd)
        finally:
            os.close(claim_fd)
    finally:
        os.close(lock_fd)
except SystemExit:
    raise
except (OSError, UnicodeError, ValueError):
    raise SystemExit(2)
PY
}

_cq_reap_claim_publish() {
  python3 - claim-publish "$1" "$2" "$3" "$4" "$5" \
    "$CQ_PROCESS_IDENTITY_HELPER" <<'PY'
import errno
import fcntl
import os
import re
import stat
import subprocess
import sys
import time

(
    _tag,
    lock,
    expected_outer,
    pid,
    token,
    identity,
    identity_helper,
) = sys.argv[1:]
parent = os.path.dirname(os.path.abspath(lock))
mutex_path = os.path.join(parent, ".critic-owner-mutex")
dir_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
dir_flags |= getattr(os, "O_DIRECTORY", 0)
dir_flags |= getattr(os, "O_NOFOLLOW", 0)
owner_flags = os.O_RDONLY | os.O_NONBLOCK
owner_flags |= getattr(os, "O_CLOEXEC", 0)
owner_flags |= getattr(os, "O_NOFOLLOW", 0)
owner_create_flags = os.O_RDWR | os.O_CREAT | os.O_EXCL
owner_create_flags |= getattr(os, "O_CLOEXEC", 0)
owner_create_flags |= getattr(os, "O_NOFOLLOW", 0)
expected_data = f"{pid} {token} {identity}\n".encode("ascii")
test_pause_limit_sec = 2.0


def generation(item):
    return f"{item.st_dev}:{item.st_ino}"


def process_identity(owner_pid):
    try:
        result = subprocess.run(
            [sys.executable, identity_helper, str(owner_pid)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        current = result.stdout.strip()
        if re.fullmatch(r"[0-9]+-[0-9]+", current) is None:
            return None
        return current
    except (OSError, subprocess.SubprocessError):
        return None


def owner_is_live(lock_fd):
    try:
        fd = os.open("owner", owner_flags, dir_fd=lock_fd)
    except OSError:
        return False
    try:
        owner_stat = os.fstat(fd)
        if (
            not stat.S_ISREG(owner_stat.st_mode)
            or owner_stat.st_uid != os.getuid()
            or stat.S_IMODE(owner_stat.st_mode) != 0o600
            or owner_stat.st_nlink != 1
            or owner_stat.st_size > 4096
        ):
            return False
        data = os.read(fd, 4097).decode("ascii")
    except (OSError, UnicodeError):
        return False
    finally:
        os.close(fd)
    match = re.fullmatch(
        r"([1-9][0-9]*) ([^ \n]+)(?: ([^ \n]+))?\n", data
    )
    if match is None:
        return False
    owner_pid = int(match.group(1))
    try:
        os.kill(owner_pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    recorded_identity = match.group(3)
    if recorded_identity is None:
        return True
    current = process_identity(owner_pid)
    return current is None or current == recorded_identity


def bounded_test_pause(path_env, label):
    """Expose a deterministic race seam without weakening the hook bound."""
    pause = os.environ.get(path_env)
    if not pause:
        return
    print(f"critic-queue-test:{label}", file=sys.stderr, flush=True)
    deadline = time.monotonic() + test_pause_limit_sec
    while os.path.exists(pause) and time.monotonic() < deadline:
        time.sleep(0.01)


try:
    mutex_flags = os.O_RDWR | os.O_NONBLOCK
    mutex_flags |= getattr(os, "O_CLOEXEC", 0)
    mutex_flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        mutex_fd = os.open(
            mutex_path, mutex_flags | os.O_CREAT | os.O_EXCL, 0o600
        )
        os.fchmod(mutex_fd, 0o600)
    except FileExistsError:
        mutex_fd = os.open(mutex_path, mutex_flags)
    mutex_stat = os.fstat(mutex_fd)
    if (
        not stat.S_ISREG(mutex_stat.st_mode)
        or mutex_stat.st_uid != os.getuid()
        or stat.S_IMODE(mutex_stat.st_mode) != 0o600
        or mutex_stat.st_nlink != 1
    ):
        raise OSError("owner coordination mutex is unsafe")
    try:
        fcntl.flock(mutex_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        if exc.errno in (errno.EACCES, errno.EAGAIN):
            raise SystemExit(1)
        raise
    lock_fd = os.open(lock, dir_flags)
    try:
        lock_stat = os.fstat(lock_fd)
        if (
            generation(lock_stat) != expected_outer
            or lock_stat.st_uid != os.getuid()
            or stat.S_IMODE(lock_stat.st_mode) != 0o700
            or owner_is_live(lock_fd)
        ):
            raise SystemExit(1)
        old_umask = os.umask(0o077)
        try:
            os.mkdir(".reap", 0o700, dir_fd=lock_fd)
        finally:
            os.umask(old_umask)
        claim_fd = os.open(".reap", dir_flags, dir_fd=lock_fd)
        try:
            claim_stat = os.fstat(claim_fd)
            if (
                claim_stat.st_uid != os.getuid()
                or stat.S_IMODE(claim_stat.st_mode) != 0o700
            ):
                raise SystemExit(1)
            if (
                os.environ.get(
                    "CQ_QUEUE_TEST_REAP_CLAIM_CRASH_AFTER_MKDIR"
                )
                == "1"
            ):
                print(
                    "critic-queue-test:claim-crash-after-mkdir",
                    file=sys.stderr,
                    flush=True,
                )
                raise SystemExit(86)

            bounded_test_pause(
                "CQ_QUEUE_TEST_REAP_CLAIM_PAUSE", "claim-ready"
            )

            # The claim fd pins the generation. If the pathname is
            # retired/reused while paused, owner creation can only affect the
            # old inode and the installed-generation check rejects success.
            publish_error = 0
            try:
                owner_fd = os.open(
                    "owner", owner_create_flags, 0o600, dir_fd=claim_fd
                )
                try:
                    os.fchmod(owner_fd, 0o600)
                    written = os.write(owner_fd, expected_data)
                    os.fsync(owner_fd)
                    if written != len(expected_data):
                        publish_error = 2
                finally:
                    os.close(owner_fd)
                installed = os.stat(
                    ".reap", dir_fd=lock_fd, follow_symlinks=False
                )
                if generation(installed) != generation(claim_stat):
                    publish_error = 1
            except OSError:
                publish_error = 2

            bounded_test_pause(
                "CQ_QUEUE_TEST_REAP_CLAIM_OBSERVE_PAUSE",
                "claim-attempted",
            )
            if publish_error:
                raise SystemExit(publish_error)
            print(generation(claim_stat))
        finally:
            os.close(claim_fd)
    finally:
        os.close(lock_fd)
        os.close(mutex_fd)
except SystemExit:
    raise
except (OSError, UnicodeError, ValueError):
    raise SystemExit(2)
PY
}

_cq_reap_claim_acquire() {
  local lock="$1" token="$2" identity="$3" expected_outer="$4"
  local owner_pid="$5"
  local claim="$1/.reap" generation
  CQ_REAP_CLAIM_GENERATION=""
  CQ_REAP_CLAIM_LOCK=""
  CQ_REAP_CLAIM_PID=""
  CQ_REAP_CLAIM_TOKEN=""
  CQ_REAP_CLAIM_IDENTITY=""

  if ! generation="$(_cq_reap_claim_publish \
      "$lock" "$expected_outer" "$owner_pid" "$token" "$identity")"; then
    return 1
  fi
  # Record the published generation before the independent ownership probe.
  # If that probe fails transiently, release can still retire the exact claim
  # instead of leaving this live process's marker to pin the queue forever.
  CQ_REAP_CLAIM_GENERATION="$generation"
  CQ_REAP_CLAIM_LOCK="$lock"
  CQ_REAP_CLAIM_PID="$owner_pid"
  CQ_REAP_CLAIM_TOKEN="$token"
  CQ_REAP_CLAIM_IDENTITY="$identity"
  if ! _cq_reap_claim_probe \
      "$lock" owned "$generation" "$owner_pid" "$token" "$identity"; then
    _cq_reap_claim_release || return 1
    return 1
  fi
}

_cq_reap_claim_state_clear() {
  CQ_REAP_CLAIM_GENERATION=""
  CQ_REAP_CLAIM_LOCK=""
  CQ_REAP_CLAIM_PID=""
  CQ_REAP_CLAIM_TOKEN=""
  CQ_REAP_CLAIM_IDENTITY=""
}

_cq_reap_claim_release() {
  local lock="${1:-$CQ_REAP_CLAIM_LOCK}"
  local owner_pid="${2:-$CQ_REAP_CLAIM_PID}"
  local token="${3:-$CQ_REAP_CLAIM_TOKEN}"
  local identity="${4:-$CQ_REAP_CLAIM_IDENTITY}"
  local claim observed_generation
  [ -n "$CQ_REAP_CLAIM_GENERATION" ] || return 0
  [ -n "$lock" ] && [ -n "$owner_pid" ] &&
    [ -n "$token" ] && [ -n "$identity" ] || return 1
  claim="$lock/.reap"

  if ! observed_generation="$(
      _cq_reap_claim_probe "$lock" generation
    )"; then
    # A positively absent pathname means our generation was already retired.
    # Any other inspection failure is ambiguous, so retain ownership state and
    # force the long-lived caller to retry rather than silently self-wedging.
    if [ ! -e "$claim" ] && [ ! -L "$claim" ]; then
      _cq_reap_claim_state_clear
      return 0
    fi
    return 1
  fi
  if [ "$observed_generation" != "$CQ_REAP_CLAIM_GENERATION" ]; then
    _cq_reap_claim_state_clear
    return 0
  fi
  _cq_reap_claim_probe "$lock" owned "$CQ_REAP_CLAIM_GENERATION" \
    "$owner_pid" "$token" "$identity" || return 1
  _cq_retire_directory "$claim" owner || return 1
  _cq_reap_claim_state_clear
}

_cq_reap_orphan_recover() {
  python3 - "$1" "$CQ_REAP_GRACE_SEC" \
    "$CQ_PROCESS_IDENTITY_HELPER" <<'PY'
import fcntl
import errno
import os
import re
import stat
import subprocess
import sys
import time

lock = os.path.abspath(sys.argv[1])
grace = int(sys.argv[2])
identity_helper = sys.argv[3]
parent = os.path.dirname(lock)
mutex_name = ".critic-reap-mutex"
mutex_path = os.path.join(parent, mutex_name)


def process_identity(pid):
    try:
        result = subprocess.run(
            [sys.executable, identity_helper, str(pid)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        identity = result.stdout.strip()
        if re.fullmatch(r"[0-9]+-[0-9]+", identity) is None:
            return None
        return identity
    except (OSError, subprocess.SubprocessError):
        return None


def process_is_live(pid, identity):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    current = process_identity(pid)
    return current is None or current == identity


def read_owner(lock_fd):
    flags = os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        owner_fd = os.open(".reap/owner", flags, dir_fd=lock_fd)
    except OSError:
        return None
    try:
        owner_stat = os.fstat(owner_fd)
        if (
            not stat.S_ISREG(owner_stat.st_mode)
            or owner_stat.st_uid != os.getuid()
            or stat.S_IMODE(owner_stat.st_mode) != 0o600
            or owner_stat.st_nlink != 1
            or owner_stat.st_size > 4096
        ):
            return None
        data = os.read(owner_fd, 4097).decode("ascii")
    except (OSError, UnicodeError):
        return None
    finally:
        os.close(owner_fd)
    match = re.fullmatch(
        r"([1-9][0-9]*) ([0-9]+-[0-9]+-[0-9]+) "
        r"([0-9]+-[0-9]+)\n",
        data,
    )
    if match is None:
        return None
    try:
        pid = int(match.group(1))
    except ValueError:
        return None
    if pid <= 0:
        return None
    return pid, match.group(2), match.group(3)


def bounded_marker_directory(parent_fd, name, expected=None):
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_DIRECTORY", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    marker_fd = os.open(name, flags, dir_fd=parent_fd)
    try:
        marker = os.fstat(marker_fd)
        if (
            marker.st_uid != os.getuid()
            or stat.S_IMODE(marker.st_mode) != 0o700
            or (
                expected is not None
                and (marker.st_dev, marker.st_ino) != expected
            )
        ):
            raise OSError("recovery marker is not private expected state")
        entries = os.listdir(marker_fd)
        if entries not in ([], ["owner"]):
            raise OSError("recovery marker contains unexpected entries")
        if entries:
            owner = os.stat("owner", dir_fd=marker_fd, follow_symlinks=False)
            if stat.S_ISDIR(owner.st_mode):
                raise OSError("recovery marker owner is an unexpected tree")
        return marker_fd, entries
    except Exception:
        os.close(marker_fd)
        raise


def remove_bounded_marker(parent_fd, name, expected):
    marker_fd, entries = bounded_marker_directory(
        parent_fd, name, expected
    )
    try:
        if entries:
            os.unlink("owner", dir_fd=marker_fd)
    finally:
        os.close(marker_fd)
    os.rmdir(name, dir_fd=parent_fd)


mutex_flags = os.O_RDWR | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0)
mutex_flags |= getattr(os, "O_NOFOLLOW", 0)
try:
    created = False
    try:
        mutex_fd = os.open(
            mutex_path, mutex_flags | os.O_CREAT | os.O_EXCL, 0o600
        )
        created = True
    except FileExistsError:
        mutex_fd = os.open(mutex_path, mutex_flags)
    if created:
        os.fchmod(mutex_fd, 0o600)
    mutex_stat = os.fstat(mutex_fd)
    if (
        not stat.S_ISREG(mutex_stat.st_mode)
        or mutex_stat.st_uid != os.getuid()
        or stat.S_IMODE(mutex_stat.st_mode) != 0o600
        or mutex_stat.st_nlink != 1
    ):
        raise OSError("recovery mutex is not private regular state")
    try:
        fcntl.flock(mutex_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit(1)
    except OSError as exc:
        if exc.errno in (errno.EACCES, errno.EAGAIN):
            raise SystemExit(1)
        raise

    lock_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    lock_flags |= getattr(os, "O_DIRECTORY", 0)
    lock_flags |= getattr(os, "O_NOFOLLOW", 0)
    lock_fd = os.open(lock, lock_flags)
    try:
        lock_stat = os.fstat(lock_fd)
        if (
            lock_stat.st_uid != os.getuid()
            or stat.S_IMODE(lock_stat.st_mode) != 0o700
        ):
            raise OSError("outer lock is not private owned state")
        marker_stat = os.stat(
            ".reap", dir_fd=lock_fd, follow_symlinks=False
        )
        recover = False
        if stat.S_ISLNK(marker_stat.st_mode):
            recover = True
        elif not stat.S_ISDIR(marker_stat.st_mode):
            recover = True
        else:
            marker_private = (
                marker_stat.st_uid == os.getuid()
                and stat.S_IMODE(marker_stat.st_mode) == 0o700
            )
            if not marker_private:
                raise OSError("recovery marker is not private state")
            # Never recursively delete a poisoned marker. An empty marker or a
            # single non-directory owner is the complete removable schema.
            bounded_fd, _bounded_entries = bounded_marker_directory(
                lock_fd, ".reap"
            )
            os.close(bounded_fd)
            owner = read_owner(lock_fd)
            if owner is not None:
                recover = not process_is_live(owner[0], owner[2])
            else:
                now = time.time()
                age = now - marker_stat.st_mtime
                if age >= grace or age < -grace:
                    recover = True
        if not recover:
            raise SystemExit(1)

        retired = ".reap.retired.%s.%s" % (os.getpid(), time.time_ns())
        os.rename(
            ".reap", retired, src_dir_fd=lock_fd, dst_dir_fd=lock_fd
        )
        retired_stat = os.stat(
            retired, dir_fd=lock_fd, follow_symlinks=False
        )
        if stat.S_ISDIR(retired_stat.st_mode):
            remove_bounded_marker(
                lock_fd,
                retired,
                (marker_stat.st_dev, marker_stat.st_ino),
            )
        else:
            os.unlink(retired, dir_fd=lock_fd)
    finally:
        os.close(lock_fd)
except SystemExit:
    raise
except (OSError, ValueError):
    raise SystemExit(2)
finally:
    try:
        os.close(mutex_fd)
    except (NameError, OSError):
        pass
PY
}

cq_queue_lock_acquire() {
  local queue="$1" lock="${1}.lock" attempt token identity snapshot owner_pid
  local generation claim_wait
  _cq_require_lock_capabilities || return 1
  # A watcher is long-lived. If its previous recovery claim could not be
  # retired, retry that exact generation before touching any queue.
  if [ -n "$CQ_REAP_CLAIM_GENERATION" ]; then
    _cq_reap_claim_release || return 1
  fi
  # A long-lived watcher retains ownership after a failed retirement so its
  # next queue operation can retry release instead of wedging on its own live
  # PID forever.
  if [ -n "$CQ_LOCK_DIR" ] || [ -n "$CQ_LOCK_TOKEN" ]; then
    cq_queue_lock_release || return 1
  fi
  _cq_current_shell_pid || return 1
  owner_pid="$CQ_CURRENT_SHELL_PID"
  token="$owner_pid-${RANDOM:-0}-$(date +%s)"
  identity="$(_cq_process_identity "$owner_pid")" || return 1
  for ((attempt=0; attempt<CQ_LOCK_WAIT_STEPS; attempt++)); do
    if generation="$(
      _cq_outer_lock_create "$lock" "$owner_pid" "$token" "$identity"
    )"; then
      # A process can resume after being frozen between mkdir and owner
      # publication. If a stale-generation reaper claimed that interval, do
      # not declare ownership until the claim is gone and this exact
      # generation plus owner token are still installed at the lock path.
      for ((claim_wait=0;
          claim_wait<CQ_LOCK_WAIT_STEPS;
          claim_wait++)); do
        [ -e "$lock/.reap" ] || [ -L "$lock/.reap" ] || break
        sleep 0.01
      done
      if [ ! -e "$lock/.reap" ] && [ ! -L "$lock/.reap" ] &&
          _cq_outer_lock_reap_probe \
            "$lock" owned "$generation" \
            "$owner_pid" "$token" "$identity"; then
        CQ_LOCK_DIR="$lock"
        CQ_LOCK_PID="$owner_pid"
        CQ_LOCK_TOKEN="$token"
        return 0
      fi
      # The claimed generation was retired or its publication was disturbed.
      # Never clean up by pathname here: it may already name a successor.
      continue
    fi

    # A reaper pins one directory generation with an in-generation mkdir
    # claim. All other reapers and the legitimate owner wait behind it. Once
    # the exact owner is revalidated under that claim, no successor can replace
    # the directory before rename. This closes the check-old/move-successor
    # race that a second reaper could otherwise trigger.
    if [ -e "$lock/.reap" ] || [ -L "$lock/.reap" ]; then
      # Fast-path a healthy live reaper without spawning the portable orphan
      # recovery helper. Dead/reused owners, partial publication, and poisoned
      # marker types are serialized under a kernel-released fcntl mutex.
      if _cq_reap_marker_is_strictly_live "$lock/.reap"; then
        sleep 0.01
        continue
      fi
      if _cq_reap_orphan_recover "$lock"; then
        continue
      fi
      sleep 0.01
      continue
    fi

    if [ -d "$lock" ] && [ ! -L "$lock" ]; then
      # Snapshot the preclaim generation and age. Publishing .reap updates the
      # directory mtime, so the postclaim decision must use this snapshot and
      # never the claim-mutated timestamp.
      if snapshot="$(_cq_outer_lock_reap_probe "$lock" pre)" &&
          _cq_reap_claim_acquire \
            "$lock" "$token" "$identity" "$snapshot" "$owner_pid"; then
        if _cq_outer_lock_reap_probe "$lock" post "$snapshot" \
            "$owner_pid" "$token" "$identity" \
            "$CQ_REAP_CLAIM_GENERATION"; then
          if _cq_retire_directory "$lock" recovery; then
            continue
          fi
        fi
        _cq_reap_claim_release || return 1
      fi
    elif [ -L "$lock" ] || { [ -e "$lock" ] && [ ! -d "$lock" ]; }; then
      return 1
    elif [ ! -e "$lock" ]; then
      # A reaper/owner may have removed the prior generation immediately after
      # this attempt's mkdir failed. Retry that normal handoff race. A genuine
      # permissions/read-only failure remains bounded by CQ_LOCK_WAIT_STEPS and
      # is reported by cq_enqueue's fail-open path.
      sleep 0.01
      continue
    fi
    sleep 0.01
  done
  return 1
}

cq_queue_lock_release() {
  local attempt rc=0
  [ -n "$CQ_LOCK_DIR" ] && [ -n "$CQ_LOCK_TOKEN" ] || return 0
  # A generation reaper may have claimed this exact directory after observing
  # a stale/reused PID. Do not remove and replace the path underneath its final
  # validation. A genuinely live owner is normally classified live and never
  # sees this wait; the bound preserves capture-hook fail-open behavior if a
  # reaper crashes mid-claim.
  for ((attempt=0; attempt<CQ_LOCK_WAIT_STEPS; attempt++)); do
    [ -e "$CQ_LOCK_DIR/.reap" ] || [ -L "$CQ_LOCK_DIR/.reap" ] || break
    sleep 0.01
  done
  if [ -e "$CQ_LOCK_DIR/.reap" ] || [ -L "$CQ_LOCK_DIR/.reap" ]; then
    return 1
  fi
  if _cq_lock_owner "$CQ_LOCK_DIR" &&
      [ "$CQ_OWNER_PID" = "$CQ_LOCK_PID" ] &&
      [ "$CQ_OWNER_TOKEN" = "$CQ_LOCK_TOKEN" ]; then
    if _cq_retire_directory "$CQ_LOCK_DIR" owner; then
      CQ_LOCK_DIR=""
      CQ_LOCK_PID=""
      CQ_LOCK_TOKEN=""
      return 0
    fi
    return 1
  else
    rc=1
  fi
  # Ownership was positively lost; never retain a path/token that could now
  # name a successor.
  CQ_LOCK_DIR=""
  CQ_LOCK_PID=""
  CQ_LOCK_TOKEN=""
  return "$rc"
}

# cq_append_line <queue> <line>
cq_append_line() {
  local queue="$1" line="$2" rc=0
  CQ_LAST_ERROR=""
  if ! cq_queue_lock_acquire "$queue"; then
    CQ_LAST_ERROR="lock"
    return 1
  fi
  printf '%s\n' "$line" >>"$queue" 2>/dev/null || rc=1
  [ "$rc" -eq 0 ] || CQ_LAST_ERROR="queue-write"
  if ! cq_queue_lock_release && [ "$rc" -eq 0 ]; then
    CQ_LAST_ERROR="lock-release"
    rc=1
  fi
  return "$rc"
}

# cq_snapshot_queue <queue> <snapshot>
# Copy a byte-exact reviewed prefix while capture writers are excluded.
cq_snapshot_queue() {
  local queue="$1" snapshot="$2" tmp rc=0
  cq_queue_lock_acquire "$queue" || return 1
  if [ ! -s "$queue" ]; then
    cq_queue_lock_release || true
    return 1
  fi
  tmp="$snapshot.tmp.$CQ_LOCK_PID-${RANDOM:-0}"
  cp "$queue" "$tmp" 2>/dev/null && mv "$tmp" "$snapshot" 2>/dev/null || rc=1
  rm -f "$tmp" 2>/dev/null || true
  if ! cq_queue_lock_release && [ "$rc" -eq 0 ]; then
    rc=1
  fi
  return "$rc"
}

# cq_consume_snapshot_prefix <queue> <snapshot>
# Remove exactly the reviewed byte prefix with an atomic replace. Appends use
# the same lock, so identical late lines remain distinguishable by position.
cq_consume_snapshot_prefix() {
  local queue="$1" snapshot="$2" tmp rc
  cq_queue_lock_acquire "$queue" || return 1
  tmp="$queue.consume.$CQ_LOCK_PID-${RANDOM:-0}"
  python3 - "$queue" "$snapshot" "$tmp" <<'PY'
import os
import sys

queue, snapshot, tmp = sys.argv[1:]
try:
    with open(snapshot, "rb") as handle:
        reviewed = handle.read()
    with open(queue, "rb") as handle:
        current = handle.read()
except OSError:
    raise SystemExit(2)

if not current.startswith(reviewed):
    raise SystemExit(3)

remaining = current[len(reviewed):]
if remaining:
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(remaining)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, queue)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
else:
    os.unlink(queue)
PY
  rc=$?
  rm -f "$tmp" 2>/dev/null || true
  if ! cq_queue_lock_release && [ "$rc" -eq 0 ]; then
    rc=1
  fi
  return "$rc"
}

# cq_enqueue <file_path> <session_id> <project_dir>
cq_enqueue() {
  local FILE_PATH="${1:-}" SESSION_ID="${2:-}" PROJECT_DIR="${3:-$PWD}"
  [ -n "$FILE_PATH" ] || return 0
  [ -n "$SESSION_ID" ] || SESSION_ID="default"

  # Absolute paths outside this project belong to some other repo's critic
  # (a session working across two checkouts edits both); queueing them here
  # gets them critiqued against the WRONG project's conventions and trunk.
  case "$FILE_PATH" in
    /*)
      case "$FILE_PATH" in
        "$PROJECT_DIR"/*) ;;
        *) return 0 ;;
      esac ;;
  esac

  # Gitignored paths (result JSONs, scratch under tmp/) are runtime artifacts,
  # never release candidates. check-ignore failing open (not a repo, git
  # missing) keeps the old behavior.
  if git -C "$PROJECT_DIR" check-ignore -q "$FILE_PATH" 2>/dev/null; then
    return 0
  fi

  local QUEUE_DIR
  if [ -d "$PROJECT_DIR/tmp" ]; then
    QUEUE_DIR="$PROJECT_DIR/tmp"
  else
    QUEUE_DIR="/tmp/shipyard-critic-$(id -u)/$(basename "$PROJECT_DIR")"
    mkdir -p "$QUEUE_DIR" 2>/dev/null || return 0
  fi

  if ! cq_append_line "$QUEUE_DIR/critic-queue-$SESSION_ID" \
      "$FILE_PATH $(date +%s)"; then
    case "$CQ_LAST_ERROR" in
      queue-write)
        printf 'critic-queue: edit capture could not write the queue file; failing open\n' >&2
        ;;
      lock-release)
        printf 'critic-queue: edit capture could not safely release the queue lock; failing open\n' >&2
        ;;
      *)
        printf 'critic-queue: edit capture could not acquire the queue lock; failing open\n' >&2
        ;;
    esac
  fi
  return 0
}

# cq_under_project <candidate> <project_dir>
# Resolve <candidate> (relative to project_dir if not absolute) and echo a
# PROJECT-RELATIVE path iff it lands inside project_dir; else echo nothing and
# return 1. Used by the codex/hermes front-ends to normalize + fence paths
# before enqueue (claude passes its own absolute paths and skips this).
# Canonicalizes `..` LEXICALLY so a traversal like `<proj>/../evil` is rejected
# — a plain string prefix check would wrongly accept it.
cq_under_project() {
  local cand="${1:-}" proj="${2:-$PWD}" abs
  [ -n "$cand" ] || return 1
  case "$cand" in
    /*) abs="$cand" ;;
    *)  abs="$proj/$cand" ;;
  esac
  # Lexical canonicalization with Python keeps missing paths valid and avoids
  # GNU realpath flags that Apple's realpath does not implement.
  abs="$(python3 -c 'import os,sys; print(os.path.abspath(os.path.normpath(sys.argv[1])))' "$abs" 2>/dev/null)" || return 1
  proj="$(python3 -c 'import os,sys; print(os.path.abspath(os.path.normpath(sys.argv[1])))' "$proj" 2>/dev/null)" || return 1
  case "$abs" in
    "$proj")     printf '.\n'; return 0 ;;
    "$proj"/*)   printf '%s\n' "${abs#"$proj"/}"; return 0 ;;
    *)           return 1 ;;
  esac
}

# cq_v4a_paths — read a V4A patch on stdin, echo one touched path per line.
# codex `apply_patch` and hermes `patch` (mode=patch) both use this format:
#   *** Add File: <path> / *** Update File: <path> / *** Delete File: <path>
cq_v4a_paths() {
  grep -oE '^\*\*\* (Add|Update|Delete) File: .+$' \
    | sed -E 's/^\*\*\* (Add|Update|Delete) File: //'
}

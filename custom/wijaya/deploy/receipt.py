#!/usr/bin/env python3
"""Fixed-path, app-only deployment receipt helper.

All on-disk operations go through a retained directory file descriptor and openat(2)-style
relative opens (os.open(..., dir_fd=...)) with O_NOFOLLOW, so the fixed receipt directory can
never be swapped for a symlink between checks. Only fixed basenames are ever used. The helper
also owns the exclusive lifecycle lock: it opens the fixed lock through the same no-follow
directory fd, validates owner/type/mode, flocks that retained fd, and re-execs the deploy script
with the locked fd inherited — the shell never validates-then-redirects the lock pathname itself.
"""
import fcntl
import hashlib
import json
import os
import re
import secrets
import stat
import sys
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
RECEIPT_DIR = os.path.join(HERE, ".receipts")
RECEIPT_FILE = os.path.join(RECEIPT_DIR, "app.json")
LOCK_FILE = os.path.join(RECEIPT_DIR, ".lock")
ASSETS_SUBDIR = "assets"
RECEIPT_NAME = "app.json"
LOCK_NAME = ".lock"
APP_SERVICES = ["rails", "sidekiq"]
# Fixed, allowlisted immutable compose asset basenames materialized per trusted commit.
ASSET_BASENAMES = ("docker-compose.deploy.yaml", "docker-compose.marine-catalog.yml")
MAX_BYTES = 65536
ASSET_MAX_BYTES = 1048576
KEYS = {"schema_version", "created_at", "target_git_sha", "app_image_id", "services", "overlay_fingerprints"}
HEX40 = re.compile(r"[0-9a-f]{40}")
HEX64 = re.compile(r"[0-9a-f]{64}")
IMAGE = re.compile(r"sha256:[0-9a-f]{64}")
UTC = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")


def reject(reason):
    print("receipt-invalid: " + reason, file=sys.stderr)
    raise SystemExit(1)


def no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            reject("duplicate-key")
        result[key] = value
    return result


def canonical(obj):
    if not isinstance(obj, dict) or set(obj) != KEYS:
        reject("unknown-or-missing-field")
    if type(obj["schema_version"]) is not int or obj["schema_version"] != 1:
        reject("unsupported-version")
    created = obj["created_at"]
    if not isinstance(created, str) or not UTC.fullmatch(created):
        reject("bad-created-at")
    try:
        datetime.strptime(created, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        reject("bad-created-at")
    if not isinstance(obj["target_git_sha"], str) or not HEX40.fullmatch(obj["target_git_sha"]):
        reject("bad-target-sha")
    if not isinstance(obj["app_image_id"], str) or not IMAGE.fullmatch(obj["app_image_id"]):
        reject("bad-app-image")
    if obj["services"] != APP_SERVICES:
        reject("incomplete-app-set")
    fingerprints = obj["overlay_fingerprints"]
    if not isinstance(fingerprints, dict) or set(fingerprints) != {"base", "catalog"}:
        reject("bad-fingerprints")
    if any(not isinstance(value, str) or not HEX64.fullmatch(value) for value in fingerprints.values()):
        reject("bad-fingerprints")
    return (json.dumps(obj, sort_keys=True, separators=(",", ":")) + "\n").encode()


def open_dirfd(path, parent_dir_fd=None):
    """Open a directory via openat/O_NOFOLLOW and prove it is an owner-only 0700 real directory."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_dir_fd)
    except OSError:
        reject("symlink-or-missing-directory")
    st = os.fstat(fd)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o700:
        os.close(fd)
        reject("bad-receipt-dir")
    return fd


def open_secure_or_none(dir_fd, name, mode=0o600):
    """openat a fixed basename, O_NOFOLLOW. Returns the validated fd, or None if simply absent;
    rejects a symlink / wrong-owner / wrong-mode / non-regular file. Never prints on absence."""
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dir_fd)
    except FileNotFoundError:
        return None
    except OSError:
        reject("symlink-or-unreadable")
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != mode:
        os.close(fd)
        reject("bad-owner-mode-or-type")
    return fd


def secure_file_fd(dir_fd, name, mode=0o600):
    """Mandatory-present variant: like open_secure_or_none but rejects when the file is absent."""
    fd = open_secure_or_none(dir_fd, name, mode)
    if fd is None:
        reject("symlink-or-unreadable")
    return fd


def mkdir_secure_at(name, parent_dir_fd=None):
    """Idempotently create an owner-only 0700 subdirectory via mkdirat, then validate + open it."""
    try:
        os.mkdir(name, 0o700, dir_fd=parent_dir_fd)
    except FileExistsError:
        pass
    return open_dirfd(name, parent_dir_fd=parent_dir_fd)


def atomic_write_at(dir_fd, name, data, mode=0o600):
    """Atomically create/replace a fixed basename under dir_fd: O_EXCL temp, fsync, rename, fsync dir."""
    temp = ".%s.%s.tmp" % (name, secrets.token_hex(12))
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode, dir_fd=dir_fd)
    try:
        view = memoryview(data)
        while view:
            view = view[os.write(fd, view):]
        os.fsync(fd)
    finally:
        os.close(fd)
    try:
        os.rename(temp, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
    except OSError:
        try:
            os.unlink(temp, dir_fd=dir_fd)
        except OSError:
            pass
        raise
    os.fsync(dir_fd)


def ensure():
    try:
        os.mkdir(RECEIPT_DIR, 0o700)
    except FileExistsError:
        pass
    st = os.lstat(RECEIPT_DIR)
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o700:
        reject("bad-receipt-dir")
    dir_fd = open_dirfd(RECEIPT_DIR)
    try:
        lock_fd = open_secure_or_none(dir_fd, LOCK_NAME)
        if lock_fd is not None:
            os.close(lock_fd)
        else:
            # Absent lock: create it O_EXCL/O_NOFOLLOW relative to the retained dir fd.
            fd = os.open(LOCK_NAME, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dir_fd)
            os.close(fd)
    finally:
        os.close(dir_fd)


def load():
    dir_fd = open_dirfd(RECEIPT_DIR)
    try:
        fd = secure_file_fd(dir_fd, RECEIPT_NAME)
        try:
            raw = os.read(fd, MAX_BYTES + 1)
        finally:
            os.close(fd)
    finally:
        os.close(dir_fd)
    if len(raw) > MAX_BYTES:
        reject("too-large")
    try:
        obj = json.loads(raw.decode(), object_pairs_hook=no_duplicates)
    except (UnicodeDecodeError, json.JSONDecodeError):
        reject("malformed-json")
    if raw != canonical(obj):
        reject("noncanonical-json")
    return obj


def write_receipt():
    raw = sys.stdin.buffer.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        reject("too-large")
    try:
        data = canonical(json.loads(raw.decode(), object_pairs_hook=no_duplicates))
    except (UnicodeDecodeError, json.JSONDecodeError):
        reject("malformed-json")
    dir_fd = open_dirfd(RECEIPT_DIR)
    try:
        # Reject replacing a symlinked/foreign receipt (O_NOFOLLOW) before the atomic swap.
        existing_fd = open_secure_or_none(dir_fd, RECEIPT_NAME)
        if existing_fd is not None:
            os.close(existing_fd)
        atomic_write_at(dir_fd, RECEIPT_NAME, data)
    finally:
        os.close(dir_fd)


def place_asset(sha, basename):
    """Durably + atomically materialize one immutable compose asset for a trusted commit.

    Writes RECEIPT_DIR/assets/<40-hex-sha>/<allowlisted-basename> from stdin bytes through
    openat/O_NOFOLLOW directory fds. Assets are persistent and immutable: a second placement with
    identical bytes is a no-op; differing bytes for an existing asset are rejected. Prints the
    sha256 of the bytes so the shell can hash-verify against the git blob fingerprint.
    """
    if not HEX40.fullmatch(sha) or basename not in ASSET_BASENAMES:
        reject("bad-asset-name")
    data = sys.stdin.buffer.read(ASSET_MAX_BYTES + 1)
    if len(data) > ASSET_MAX_BYTES:
        reject("asset-too-large")
    if not data:
        reject("empty-asset")
    dir_fd = open_dirfd(RECEIPT_DIR)
    try:
        assets_fd = mkdir_secure_at(ASSETS_SUBDIR, parent_dir_fd=dir_fd)
        try:
            commit_fd = mkdir_secure_at(sha, parent_dir_fd=assets_fd)
            try:
                fd = open_secure_or_none(commit_fd, basename)
                if fd is not None:
                    try:
                        existing = os.read(fd, ASSET_MAX_BYTES + 1)
                    finally:
                        os.close(fd)
                    if existing != data:
                        reject("asset-immutability-violation")
                else:
                    atomic_write_at(commit_fd, basename, data)
            finally:
                os.close(commit_fd)
        finally:
            os.close(assets_fd)
    finally:
        os.close(dir_fd)
    print(hashlib.sha256(data).hexdigest(), end="")


def lock_exec(argv):
    """Open the fixed lock via the no-follow dir fd, validate, flock it, and exec the deploy script.

    The locked fd is marked inheritable and its number is exported as MARINE_LIFECYCLE_LOCK_FD so
    the re-exec'd deploy script runs under the already-held lock without ever reopening the lock
    pathname itself (no shell validate-then-redirect race).
    """
    if not argv:
        reject("usage")
    script = argv[0]
    ensure()
    dir_fd = open_dirfd(RECEIPT_DIR)
    try:
        try:
            lock_fd = os.open(LOCK_NAME, os.O_RDWR | os.O_NOFOLLOW, dir_fd=dir_fd)
        except OSError:
            reject("symlink-or-unreadable")
        st = os.fstat(lock_fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o600:
            os.close(lock_fd)
            reject("bad-lock-owner-mode-or-type")
    finally:
        os.close(dir_fd)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("another deploy/rollback is already in progress (lifecycle lock held); refusing to proceed",
              file=sys.stderr)
        raise SystemExit(1)
    os.set_inheritable(lock_fd, True)
    os.environ["MARINE_LIFECYCLE_LOCK_FD"] = str(lock_fd)
    # Export the ORIGINAL device+inode read from the RETAINED lock fd (st = fstat(lock_fd) above) —
    # unforgeable, kernel-backed identity captured at open time. verify-inherited-fd binds the
    # inherited fd to EXACTLY this exported original (never re-derived from the pathname at verify
    # time), so a forged numeric marker pointing at some other inherited fd (a memfd or an unrelated
    # 0600 regular file), or a later replacement/hard-link of the .lock pathname, cannot masquerade
    # as the lifecycle lock.
    os.environ["MARINE_LIFECYCLE_LOCK_DEV"] = str(st.st_dev)
    os.environ["MARINE_LIFECYCLE_LOCK_INO"] = str(st.st_ino)
    try:
        os.execvp("bash", ["bash", script] + list(argv[1:]))
    except OSError:
        reject("exec-failed")


def verify_inherited_fd(raw_fd):
    """Validate an INHERITED retained lifecycle-lock fd by binding it to the ORIGINAL lock identity.

    lock-exec opened the canonical lock, flocked the RETAINED fd, and exported THAT fd's ORIGINAL
    device+inode (MARINE_LIFECYCLE_LOCK_DEV/INO). This second pass trusts no numeric marker and no
    verify-time pathname: it FIRST requires the inherited fd's fstat device+inode to EXACTLY equal
    the exported original dev+ino, and only THEN verifies owner, regular-file type, mode 0600, and
    that the exclusive flock is still held. It also safely re-validates the canonical directory and
    .lock file (owner-only 0700 dir via openat/O_NOFOLLOW; .lock not a symlink), but the re-opened
    pathname may only CORROBORATE the exported original identity — it can NEVER redefine it. So a
    forged fd (a closed fd, a wrong-mode fd, a 0600 memfd, or an unrelated 0600 regular file) whose
    dev/ino differs from the original is rejected, and replacing/hard-linking the .lock pathname
    after lock-exec cannot move the expected identity: a genuine fd whose canonical pathname was
    swapped still fails closed on the canonical corroboration.

    This is COOPERATIVE lifecycle serialization against replacement/TOCTOU races between cooperating
    deploy/rollback runs — NOT privilege isolation from the same Unix owner (who can always open or
    flock the lock directly); its only job is to keep two well-behaved runs from overlapping.
    """
    if not re.fullmatch(r"[0-9]+", raw_fd):
        reject("bad-lock-fd")
    fd = int(raw_fd)
    exp_dev = os.environ.get("MARINE_LIFECYCLE_LOCK_DEV", "")
    exp_ino = os.environ.get("MARINE_LIFECYCLE_LOCK_INO", "")
    if not re.fullmatch(r"[0-9]+", exp_dev) or not re.fullmatch(r"[0-9]+", exp_ino):
        reject("missing-original-lock-identity")
    # FIRST: the inherited fd must be byte-for-byte the ORIGINALLY opened lock inode (dev+ino as
    # captured by lock-exec from the retained fd), before any other property is trusted.
    try:
        st = os.fstat(fd)
    except OSError:
        reject("closed-or-invalid-lock-fd")
    if st.st_dev != int(exp_dev) or st.st_ino != int(exp_ino):
        reject("inherited-fd-not-original-lock")
    # Only THEN: owner-only 0600 regular file.
    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o600:
        reject("bad-lock-owner-mode-or-type")
    # Safely corroborate the canonical directory/.lock, but NEVER let the verify-time pathname
    # redefine the expected identity: the re-opened .lock must ITSELF still equal the exported
    # original dev+ino, else the pathname was replaced/hard-linked and we fail closed.
    dir_fd = open_dirfd(RECEIPT_DIR)
    try:
        lst = os.lstat(LOCK_NAME, dir_fd=dir_fd)
        if stat.S_ISLNK(lst.st_mode):
            reject("symlink-or-unreadable")
        canon_fd = secure_file_fd(dir_fd, LOCK_NAME)
        try:
            canon = os.fstat(canon_fd)
        finally:
            os.close(canon_fd)
    finally:
        os.close(dir_fd)
    if canon.st_dev != int(exp_dev) or canon.st_ino != int(exp_ino):
        reject("canonical-lock-path-replaced")
    # Finally: the exclusive flock must still be held on the inherited fd.
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        reject("lifecycle-lock-not-held")
    print("OK inherited-lock-fd=%d" % fd)


def main():
    if len(sys.argv) < 2:
        reject("usage")
    command = sys.argv[1]
    if command == "ensure" and len(sys.argv) == 2:
        ensure()
    elif command == "validate" and len(sys.argv) == 2:
        obj = load()
        fp = obj["overlay_fingerprints"]
        print("OK target=%s app=%s services=rails,sidekiq fp_base=%s fp_catalog=%s" %
              (obj["target_git_sha"], obj["app_image_id"], fp["base"], fp["catalog"]))
    elif command == "write" and len(sys.argv) == 2:
        write_receipt()
    elif command == "place-asset" and len(sys.argv) == 4:
        place_asset(sys.argv[2], sys.argv[3])
    elif command == "lock-exec" and len(sys.argv) >= 3:
        lock_exec(sys.argv[2:])
    elif command == "verify-inherited-fd" and len(sys.argv) == 3:
        verify_inherited_fd(sys.argv[2])
    elif command == "sha256" and len(sys.argv) == 3:
        source = sys.stdin.buffer if sys.argv[2] == "-" else open(sys.argv[2], "rb")
        try:
            print(hashlib.sha256(source.read()).hexdigest(), end="")
        finally:
            if source is not sys.stdin.buffer:
                source.close()
    else:
        reject("usage")


if __name__ == "__main__":
    main()

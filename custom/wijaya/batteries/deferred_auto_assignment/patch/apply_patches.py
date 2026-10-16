#!/usr/bin/env python3
"""Idempotently restore the DeferredAutoAssignment Sidekiq schedule hook."""

from __future__ import annotations

import argparse
import os
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[5]
TARGET = Path("config/schedule.yml")
START = "# WIJAYA_CUSTOM_START deferred_auto_assignment"
END = "# WIJAYA_CUSTOM_END deferred_auto_assignment"
ANCHOR = """# executed every 12 hours
# to remove orphan conversations without contact
remove_orphan_conversations_job:
  cron: '0 */12 * * *'
  class: 'Internal::RemoveOrphanConversationsJob'
  queue: housekeeping
"""
BLOCK = """# WIJAYA_CUSTOM_START deferred_auto_assignment
# executed hourly (at minute 15)
# Low-frequency crash-gap RECOVERY DRAINER + run-intent COORDINATOR (durable-outbox fallback, NOT the
# primary deletion mechanism). Each tick selects AT MOST ONE persisted run intent and runs the
# Reconciler INLINE under its global advisory lock — it does NOT hand off to a second Redis queue, so
# there is exactly one queued unit (this cron occurrence) per tick and no downstream retry tree. It
# queries ONLY unreconciled deferred-assignment deletion-provenance tombstones — never a blanket scan
# of Unassigned conversations — and opens a fresh recovery generation only when no incomplete run
# remains and a straggler exists. Self-gating: no provenance and no incomplete run, no work. Permitted
# as a scheduled job precisely because it is provenance-scoped.
wijaya_deferred_assignment_recovery_drainer_job:
  cron: '15 * * * *'
  class: 'Wijaya::Batteries::DeferredAutoAssignment::RecoveryDrainerJob'
  queue: scheduled_jobs
  # Explicit because this Battery ApplicationJob may not be constantized when sidekiq-cron enqueues.
  active_job: true
# WIJAYA_CUSTOM_END deferred_auto_assignment
"""


class PatchError(RuntimeError):
    """The target cannot be patched without guessing."""


def target_for(root: Path) -> Path:
    return root / TARGET


def validate(content: str) -> None:
    starts = content.count(START)
    ends = content.count(END)
    if starts != 1 or ends != 1:
        if starts == 0 and ends == 0:
            raise PatchError("missing DeferredAutoAssignment schedule marker block")
        if starts != ends:
            raise PatchError("partial DeferredAutoAssignment schedule marker block")
        raise PatchError("duplicate DeferredAutoAssignment schedule marker blocks")
    if content.count(BLOCK) != 1:
        raise PatchError("DeferredAutoAssignment schedule marker block differs from the registered contract")


def atomic_write(path: Path, content: str) -> None:
    mode = path.stat().st_mode
    temporary = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
            temporary = Path(handle.name)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def apply(root: Path = ROOT) -> bool:
    target = target_for(root)
    if not target.is_file():
        raise PatchError(f"missing target {target}")

    content = target.read_text(encoding="utf-8")
    if START in content or END in content:
        validate(content)
        return False

    if content.count(ANCHOR) != 1:
        raise PatchError("expected remove_orphan_conversations_job insertion context exactly once")

    updated = content.replace(ANCHOR, f"{ANCHOR}\n{BLOCK}", 1)
    validate(updated)
    atomic_write(target, updated)
    return True


def check(root: Path = ROOT) -> None:
    target = target_for(root)
    if not target.is_file():
        raise PatchError(f"missing target {target}")
    validate(target.read_text(encoding="utf-8"))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="verify the exact block without applying it")
    args = parser.parse_args()

    try:
        if args.check:
            check()
            print("deferred_auto_assignment schedule hook verified")
        elif apply():
            print("deferred_auto_assignment schedule hook applied")
        else:
            print("deferred_auto_assignment schedule hook already present")
    except PatchError as error:
        raise SystemExit(f"deferred_auto_assignment patch error: {error}") from error


if __name__ == "__main__":
    main()

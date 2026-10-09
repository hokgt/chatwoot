#!/usr/bin/env python3
"""Idempotently restore the Marine memory Sidekiq schedule hook."""

from __future__ import annotations

import os
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[5]
TARGET = ROOT / "config/schedule.yml"
START = "# WIJAYA_CUSTOM_START marine_ai"
END = "# WIJAYA_CUSTOM_END marine_ai"
ANCHOR = "# WIJAYA_CUSTOM_END deferred_auto_assignment\n"
BLOCK = """# WIJAYA_CUSTOM_START marine_ai
# Daily 02:00 Asia/Jakarta checkpoint for unresolved, idle Marine conversations.
# The battery job is self-gating: it skips disabled assistants, resolved conversations,
# active conversations, and ranges without a new public incoming customer message.
wijaya_marine_memory_checkpoint_job:
  cron: '0 2 * * * Asia/Jakarta'
  class: 'Marine::Memory::CheckpointJob'
  queue: low
# WIJAYA_CUSTOM_END marine_ai
"""


def fail(message: str) -> None:
    raise SystemExit(f"marine_ai patch error: {message}")


def atomic_write(path: Path, content: str) -> None:
    mode = path.stat().st_mode
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as handle:
        handle.write(content)
        temporary = Path(handle.name)
    os.chmod(temporary, mode)
    os.replace(temporary, path)


def main() -> None:
    if not TARGET.is_file():
        fail(f"missing target {TARGET}")

    content = TARGET.read_text()
    has_start = START in content
    has_end = END in content

    if has_start or has_end:
        if not (has_start and has_end):
            fail("partial Marine schedule marker block")
        if content.count(START) != 1 or content.count(END) != 1:
            fail("duplicate Marine schedule marker blocks")
        if BLOCK not in content:
            fail("Marine schedule marker block differs from the registered contract")
        print("marine_ai schedule hook already present")
        return

    if content.count(ANCHOR) != 1:
        fail("expected deferred_auto_assignment anchor exactly once")

    updated = content.replace(ANCHOR, f"{ANCHOR}\n{BLOCK}", 1)
    atomic_write(TARGET, updated)
    print("marine_ai schedule hook applied")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Guard dev.127 source-wake closure after dev.132 removes startup gating."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
read = lambda path: (ROOT / path).read_text(encoding="utf-8")
coordinator = read("packages/sessions/lib/src/live_coordinator.dart")
agents = read("AGENTS.md")

for forbidden in (
    "sameStartupCurrent",
    "isStartupBuffering",
    "decode-startup-deferred",
    "_startupBufferingCurrent",
):
    if forbidden in coordinator:
        raise SystemExit(f"startup-only refill branch remains after supersession: {forbidden}")
if coordinator.count("animation.frameCount <= 1 &&") != 1:
    raise SystemExit("static single-frame satisfaction must remain singular")
for required in (
    "_hasPendingSourceRevision(decision.id)",
    "_wakeNextDecodeRefill(sessionId, except: id)",
):
    if required not in coordinator:
        raise SystemExit(f"source/refill wake closure missing: {required}")
if '"$(python3 tool/workspace_config.py patch_dir --absolute)/<patch-file>"' not in agents:
    raise SystemExit("patch command policy missing")
print("dev.127 source-wake closure after startup-gate removal: OK")

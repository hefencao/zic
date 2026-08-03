#!/usr/bin/env python3
"""Guard dev.104 artifact-read quanta and retained cursor continuity."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def require(relative: str, *tokens: str) -> None:
    text = read(relative)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f"FAIL: {relative} missing tokens: {missing}")


require(
    "packages/downloads/lib/src/artifact_cache_read_scheduler.dart",
    "this.maxBackgroundWhileForeground = 1",
    "int _activeForeground = 0",
    "bool get _hasForegroundPressure",
    "_activeBackground < maxBackgroundWhileForeground",
    "final bool foreground",
)
require(
    "packages/downloads/lib/src/artifact_cache_transport.dart",
    "final iterator = StreamIterator<List<int>>(response.bytes)",
    "if (!activeLease.foreground || !stillForeground)",
    "readSchedulerMaxWaitMicros",
    "readSchedulerAcquires",
    "readSchedulerForegroundAcquires",
)
require(
    "packages/sessions/lib/src/decode_session.dart",
    "final retainedDepth = _holder?.depth ?? 0",
    "_restartAfterDetach = retainedDepth == 0",
)
decode = read("packages/sessions/lib/src/decode_session.dart")
if "_holder?.trimTo(retainDepth);\n    _restartAfterDetach = true;" in decode:
    raise SystemExit("FAIL: retained frame detach still forces cursor restart")

require(
    "packages/sessions/test/decode_session_test.dart",
    "retained frame detach preserves cursor continuation",
    "expect(decode.holder!.frames.map((frame) => frame.index), <int>[1, 2])",
    "expect(cursors.created, 1)",
)
require(
    "packages/downloads/test/artifact_cache_transport_test.dart",
    "background artifact stream reacquires the scheduler per chunk",
    "foreground artifact stream keeps its scheduler lease across chunks",
    "background promotion reclassifies the next chunk without reopening",
    "readSchedulerAcquires",
)
require(
    "docs/audits/dev104-startup-congestion-cursor-continuity-audit.md",
    "问题清单",
    "所有权清单",
    "被否决方案清单",
)

print("dev.104 startup congestion and cursor continuity: OK")

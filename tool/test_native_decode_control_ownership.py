#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(
            f"FAIL: {path} missing native decode control ownership tokens: {missing}"
        )


def forbid(path: str, *tokens: str) -> None:
    text = read(path)
    found = [token for token in tokens if token in text]
    if found:
        raise SystemExit(
            f"FAIL: {path} contains rejected native decode scheduling tokens: {found}"
        )


require(
    "packages/media/lib/src/frame.dart",
    "TaskControl? control",
)
require(
    "packages/sessions/lib/src/decode_session.dart",
    "control: cancel",
)
require(
    "packages/bridge/lib/src/native_cursor.dart",
    "control: control",
)
require(
    "packages/bridge/lib/src/native_decode_pool.dart",
    "TaskControl? control",
    "control.whenCancelled.then",
    "pending.control?.priority ?? 0",
    "pending.sequence < best.sequence",
    "nonCurrentBusy >= liveWorkerCount - 1",
    "_removePending(pending)",
)
forbid(
    "packages/bridge/lib/src/native_decode_pool.dart",
    "_nonCurrentPending.removeFirst()",
    "_currentPending.removeFirst()",
    "prioritySubscription",
    "control.priorityChanges.listen",
    "int priority;",
)

pool = read("packages/bridge/lib/src/native_decode_pool.dart")
cancel_block = pool.split("control.whenCancelled.then", 1)[1].split(
    "void _completeCancelledPending", 1
)[0]
if "worker.busy = false" in cancel_block or "_activeRuns--" in cancel_block:
    raise SystemExit(
        "FAIL: queued cancellation must not release admitted worker capacity"
    )

print("native decode pending cancellation/rank ownership: OK")

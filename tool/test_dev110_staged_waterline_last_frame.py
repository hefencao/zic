#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def require(path: str, *needles: str) -> None:
    text = (ROOT / path).read_text(encoding="utf-8")
    for needle in needles:
        if needle not in text:
            raise SystemExit(f"FAIL: {path} missing {needle!r}")


def forbid(path: str, *needles: str) -> None:
    text = (ROOT / path).read_text(encoding="utf-8")
    for needle in needles:
        if needle in text:
            raise SystemExit(f"FAIL: {path} still contains {needle!r}")


require(
    "packages/pipeline/lib/src/role_window.dart",
    "PageRole.last",
    "PageRole.next2",
    "previousCurrentIndex",
    "roles[index] == PageRole.last",
    "forwardSlot < forwardEncodedPages",
    "backwardSlot < backwardEncodedPages",
)
require(
    "packages/pipeline/lib/src/pipeline_controller.dart",
    "_lastCurrentIndex",
    "_lastCurrentIndex = _currentIndex",
    "previousCurrentIndex: _lastCurrentIndex",
)
require(
    "packages/pipeline/lib/src/heuristic_policy.dart",
    "PageRole.current => 7",
    "PageRole.next => decodeWarmPages ? 5 : 0",
    "PageRole.next2 => decodeWarmPages ? 3 : 0",
    "PageRole.previous => decodeWarmPages ? 2 : 0",
    "role == PageRole.last",
    "PageRole.last => 0",
)
require(
    "packages/sessions/lib/src/decode_refill_policy.dart",
    "c>2",
    "transition ?? byRole[PageRole.next]",
    "n>1",
    "m>1",
    "p>1",
    "c>4",
    "c>6",
    "n>4",
)
require(
    "packages/sessions/lib/src/live_coordinator.dart",
    "StagedDecodeRefillPolicy",
    "TraceEventKind.decodeRefill",
    "entry.value.role == PageRole.last",
    "upload.cancel(entry.key.key)",
    "TraceEventKind.lastFrameKept",
    "sourceWake: _hasPendingSourceRevision(refill.id)",
    "uploadRegistry.resumePlayback(entry.key)",
    "onFrameReady: _uploads.containsKey(id)",
)
require(
    "packages/sessions/lib/src/frame_budget.dart",
    "_protectsOutput",
    "role == PageRole.last",
)
require(
    "packages/pipeline_runtime/lib/src/pipeline_page_output.dart",
    "_presentationPending",
    "_finishPresentation",
    "scheduleMicrotask",
)
forbid(
    "packages/pipeline_runtime/lib/src/pipeline_page_output.dart",
    "final generation = ++_generation",
)
require(
    "packages/sessions/lib/src/decode_session.dart",
    "onFrameReady?.call(snapshot)",
)
require(
    "packages/sessions/test/decode_refill_policy_test.dart",
    "staged waterlines refill one role at a time",
    "transition is the logical next across every staged watermark",
    "expectStep(PageRole.current, 3)",
    "expectStep(PageRole.next, 5)",
)
require(
    "packages/pipeline/test/pipeline_test.dart",
    "previous current remains last and keeps upload without decode refill",
)
print("dev.110 staged waterline/last-frame contract: OK")

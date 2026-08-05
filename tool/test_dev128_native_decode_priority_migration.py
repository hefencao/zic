#!/usr/bin/env python3
"""Guard dev.128 queued native-decode priority migration."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.128 contract: {token}")

media = read("packages/media/lib/src/frame.dart")
bridge = read("packages/bridge/lib/bridge.dart")
pool = read("packages/bridge/lib/src/native_decode_pool.dart")
cursor = read("packages/bridge/lib/src/native_cursor.dart")
session = read("packages/sessions/lib/src/decode_session.dart")
registry = read("packages/sessions/lib/src/decode_registry.dart")
coordinator = read("packages/sessions/lib/src/live_coordinator.dart")
owner_test = read("packages/sessions/test/decode_session_test.dart")
coordinator_test = read("packages/sessions/test/live_coordinator_test.dart")
analyzer = read("tool/analyze_frame_pipeline_trace.py")
check = read("tool/check.sh")

for token in (
    "enum DecodePriorityPromotion { none, queued, active }",
    "abstract interface class PrioritizableScheduledFrameCursor",
    "DecodePriorityPromotion promotePendingDecodeToCurrent()",
):
    require(media, token, "media cursor priority capability")

for token in (
    "DecodePriorityPromotion,",
    "PrioritizableScheduledFrameCursor,",
):
    require(bridge, token, "bridge public priority capability export")

for token in (
    "DecodePriorityPromotion promotePendingDecodeToCurrent({",
    "_nonCurrentPending.remove(pending)",
    "pending.executionClass = DecodeExecutionClass.current",
    "_currentPending.addFirst(pending)",
    "worker.cursorAddress != cursorAddress",
    "worker.executionClass = DecodeExecutionClass.current",
    "_markQueuedWorkersReady()",
):
    require(pool, token, "native worker-pool migration")

for token in (
    "implements PrioritizableScheduledFrameCursor, LoopCursor",
    "return _decodePool.promotePendingDecodeToCurrent(",
):
    require(cursor, token, "NativeCursor priority projection")

require(session, "DecodePriorityPromotion promotePendingDecodeToCurrent()", "DecodeSession")
require(registry, "promotePendingDecodeToCurrent(DecodeId id)", "DecodeRegistry")
for token in (
    "TraceEventKind.decodePriorityPromoted",
    "_promoteDecodeToCurrent(sessionId, entry.key, demandRevision)",
    "decodes?.promotePendingDecodeToCurrent(id)",
):
    require(coordinator, token, "LiveCoordinator current-role migration")

for token in (
    "promotes an already queued native-style decode when page becomes current",
    "DecodePriorityPromotion.queued",
    "session.promotePendingDecodeToCurrent()",
):
    require(owner_test, token, "sessions owner test")

for token in (
    "role promotion reaches an already active cursor decode request",
    "TraceEventKind.decodePriorityPromoted",
    "expect(cursors.cursor.promotions, 1)",
):
    require(coordinator_test, token, "LiveCoordinator owner test")

for token in (
    '"decodePriorityPromotionCount"',
    '"decodeQueuedPriorityPromotionCount"',
    '"decodeActivePriorityPromotionCount"',
):
    require(analyzer, token, "Trace analyzer decode-priority diagnostics")

require(check, "test_dev128_native_decode_priority_migration.py", "repository check")
print("dev.128 native decode priority migration contract: OK")

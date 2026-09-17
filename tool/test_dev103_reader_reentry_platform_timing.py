#!/usr/bin/env python3
"""Guard dev.103 Reader re-entry and platform timing ownership."""

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
    "packages/telemetry/lib/src/clock.dart",
    "static final Stopwatch _watch",
    "const SystemClock()",
)

for relative in (
    "apps/app/lib/demo_home.dart",
    "apps/app/lib/source_browser.dart",
    "apps/app/lib/comic_details.dart",
):
    require(relative, "const SystemClock()")
    if "Stopwatch _traceClock" in read(relative):
        raise SystemExit(
            f"FAIL: {relative} owns a route-local trace Stopwatch instead of the shared process clock"
        )

require(
    "packages/telemetry/lib/src/trace.dart",
    "readerSessionCreated",
    "readerSessionDisposeStarted",
    "readerSessionDisposed",
)
require(
    "packages/pipeline_runtime/lib/src/pipeline_reader_session.dart",
    "TraceEventKind.readerSessionCreated",
    "TraceEventKind.readerSessionDisposeStarted",
    "TraceEventKind.readerSessionDisposed",
    "artifactReadScheduler.refresh()",
)
require(
    "packages/texture_bridge/android/src/main/kotlin/dev/zic/texture/TextureBridgePlugin.kt",
    "channel = MethodChannel(",
    "BLIT_LANE_COUNT = 1",
    "blitLanes.forEach { lane -> lane.execute {} }",
    "if (mainHandler.post(::drainProducerSchedules))",
    "val lane: ExecutorService",
)

kotlin = read(
    "packages/texture_bridge/android/src/main/kotlin/dev/zic/texture/TextureBridgePlugin.kt"
)
for forbidden in (
    "CountDownLatch",
    "completed.await()",
    "makeBackgroundTaskQueue",
    "postAtFrontOfQueue",
):
    if forbidden in kotlin:
        raise SystemExit(f"FAIL: obsolete global blocking texture lane remains: {forbidden}")

require(
    "packages/sessions/lib/src/upload_session.dart",
    "final rolePromoted =",
    "decodedTiming.role != demand.role",
    "presentationAckCreditMicros",
    "presentationVisibleAtMicros",
    "platformTiming.channelDispatchMicros",
)
require(
    "tool/analyze_frame_pipeline_trace.py",
    '"per-session-legacy-clock"',
    'event.get("kind") == "readerSessionCreated"',
    'decoded_role != upload_role',
)

print("dev.103 Reader re-entry and platform timing ownership: OK")

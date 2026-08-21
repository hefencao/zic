#!/usr/bin/env python3
"""Guard texture schedule timing decomposition and stable quarantine IDs."""

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
    "packages/texture_bridge/android/src/main/kotlin/dev/zic/texture/TextureBridgePlugin.kt",
    "data class ScheduleResult",
    '"initialize" -> initialize(call, result)',
    "output.initialize()",
    "SurfaceProducer#getSurface()",
    "scheduleQueueMicros",
    "scheduleCallMicros",
    "complete: (ScheduleResult) -> Unit",
    "val request = PendingProducerSchedule(",
    "pendingSchedules += request",
    "IdentityHashMap<",
    "scheduledProducers",
    "postFrameCallback(scheduleBoundaryCallback)",
    "private fun onScheduleBoundary()",
    "if (mainHandler.post(::drainProducerSchedules))",
    "completionExecutor: ExecutorService",
    "scheduleCompletionExecutor = newScheduleCompletionExecutor()",
    "completionExecutor?.shutdown()",
    "dispatchScheduleCompletion(request, result)",
    "result.success(value)",
)
require(
    "packages/texture_bridge/lib/src/android_texture_presenter.dart",
    "scheduleQueueMicros",
    "scheduleCallMicros",
)
require(
    "packages/media/lib/src/output.dart",
    "platformScheduleQueueMicros",
    "platformScheduleCallMicros",
)
require(
    "packages/sessions/lib/src/upload_session.dart",
    "'platformScheduleQueue'",
    "'platformScheduleCall'",
    "'platformScheduleQueueMicros'",
    "'platformScheduleCallMicros'",
)
require(
    "tool/analyze_frame_pipeline_trace.py",
    "platformScheduleLegacyMicros",
    "platformScheduleQueueMicros",
    "platformScheduleCallMicros",
)
require(
    "docs/testing/TEST_QUARANTINE.md",
    "Q-001",
    "Q-002",
    "Q-003",
)
for marker in (
    "ZIC-QUARANTINE(Q-001):",
    "ZIC-QUARANTINE(Q-002):",
    "ZIC-QUARANTINE(Q-003):",
):
    require("apps/app/test/source_browser_test.dart", marker)

kotlin = read(
    "packages/texture_bridge/android/src/main/kotlin/dev/zic/texture/TextureBridgePlugin.kt"
)
if any(
    token in kotlin
    for token in (
        "CountDownLatch",
        "completed.await()",
        "makeBackgroundTaskQueue",
        "postAtFrontOfQueue",
    )
):
    raise SystemExit("FAIL: texture blit lane must not block on platform schedule")
if "mainHandler.post { result.success" in kotlin or "mainHandler.post { result.error" in kotlin:
    raise SystemExit("FAIL: schedule completion must not be marshalled through the UI looper")

print("texture schedule timing and quarantine contract: OK")

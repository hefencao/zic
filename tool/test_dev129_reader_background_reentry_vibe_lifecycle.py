#!/usr/bin/env python3
"""Guard dev.129 fresh texture ownership and deadline-driven playback."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.129 contract: {token}")

runtime = read("packages/pipeline_native/lib/src/native_pipeline_media_runtime.dart")
media = read("packages/media/lib/src/output.dart")
upload_session = read("packages/sessions/lib/src/upload_session.dart")
session = read("packages/pipeline_runtime/lib/src/pipeline_reader_session.dart")
upload = read("packages/sessions/lib/src/upload_session.dart")
registry = read("packages/sessions/lib/src/upload_registry.dart")
analyzer = read("tool/analyze_frame_pipeline_trace.py")
android_performance = read("native/media_core/src/android_performance.rs")
native_lib = read("native/media_core/src/lib.rs")
native_header = read("native/media_core/include/media_core.h")
native_pool = read("packages/bridge/lib/src/native_decode_pool.dart")
native_cursor = read("packages/bridge/lib/src/native_cursor.dart")
frame = read("packages/media/lib/src/frame.dart")
decode_session = read("packages/sessions/lib/src/decode_session.dart")
role_window = read("packages/pipeline/lib/src/role_window.dart")
check = read("tool/check.sh")

for token in (
    "with WidgetsBindingObserver",
    "didChangeAppLifecycleState(ui.AppLifecycleState state)",
    "unawaited(_releaseIdleWithoutSurfacingFailure(pool))",
    "Future<void> releaseIdle() async",
    "await value.lease.release()",
):
    require(runtime, token, "fresh Android texture lifecycle")

for forbidden in (
    "RetainedOutputUploader",
    "restoreRetainedOutput",
    "_retainedRestoreAttempted",
    "final class _RetainedTextureFrame",
    "_RetainedAndroidTextureOutputFrame",
    "slot.markPresented(frame)",
):
    if forbidden in runtime + media + upload_session:
        raise SystemExit(f"dev.129 must not retain cross-Reader output: {forbidden}")

for token in (
    "int? get playbackDeadlineMicros => _playback.deadlineUs",
    "int? earliestPlaybackDeadlineMicros(Iterable<DecodeId> ids)",
):
    require(upload + registry, token, "deadline projection")

for token in (
    "_uploads.earliestPlaybackDeadlineMicros(ids)",
    "Duration(microseconds: remainingMicros > 0 ? remainingMicros : 0)",
    "_cancelPlaybackWake()",
):
    require(session, token, "one-shot playback wake")
if "Timer.periodic(" in session:
    raise SystemExit("dev.129 must not poll playback with Timer.periodic")

for token in (
    '"textureLeaseReusedBridgeOver100msCount"',
    '"textureLeaseReusedBridgeMicros"',
    '"textureLeaseReusedScheduleQueueMicros"',
):
    require(analyzer, token, "reentry texture analyzer")

for token in (
    "sched_setaffinity",
    "max_frequency.saturating_mul(8) / 10",
    "cpuinfo_max_freq",
    "scaling_max_freq",
):
    require(android_performance, token, "Android performance-core placement")
for token in (
    "mod android_performance;",
    "zic_prepare_decode_thread",
):
    require(native_lib, token, "native decode-thread ABI")
require(native_header, "zic_prepare_decode_thread", "native header")
for token in (
    "api.prepareDecodeThread()",
    "workerPlacementStatus",
):
    require(native_pool, token, "native decode worker placement")
require(native_cursor, "prepareDecodeThread", "native cursor ABI")
require(frame, "workerPlacementStatus", "frame timing projection")
require(
    decode_session,
    "'workerPlacementStatus': frameTiming.workerPlacementStatus",
    "decode trace",
)
for token in (
    '"decodeWorkerPlacementStatusCounts"',
    '"decodeWorkerAffinityAppliedCount"',
    '"decodeWorkerPlacements"',
):
    require(analyzer, token, "decode worker placement analyzer")

if "PageRole.visible" in role_window:
    raise SystemExit("dev.129 must not restore visible-page demand")
require(check, "test_dev129_reader_background_reentry_vibe_lifecycle.py", "repository check")
print("dev.129 reader background reentry / Vibe lifecycle contract: OK")

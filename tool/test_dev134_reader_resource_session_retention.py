#!/usr/bin/env python3
"""Guard bounded Reader resource-session retention and affinity removal."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.134 contract: {token}")


host = read("packages/pipeline_runtime/lib/src/pipeline_reader_host.dart")
session = read("packages/pipeline_runtime/lib/src/pipeline_reader_session.dart")
trace = read("packages/telemetry/lib/src/trace.dart")
analyzer = read("tool/analyze_frame_pipeline_trace.py")
native_pool = read("packages/bridge/lib/src/native_decode_pool.dart")
native_cursor = read("packages/bridge/lib/src/native_cursor.dart")
native_lib = read("native/media_core/src/lib.rs")
native_header = read("native/media_core/include/media_core.h")
native_identity = read("native/media_core/ANDROID_NATIVE_BUILD_ID").strip()
kotlin = read(
    "packages/texture_bridge/android/src/main/kotlin/dev/zic/texture/TextureBridgePlugin.kt"
)
owner_test = read("packages/pipeline_runtime/test/media_runtime_ownership_test.dart")
check = read("tool/check.sh")

for token in (
    "_ownerFactory.acquire(",
    "_ownerFactory.release(_session)",
):
    require(host, token, "Reader host retention")
for forbidden in ("widget.factory.create(", "_session.dispose()"):
    if forbidden in host:
        raise SystemExit(f"Reader host must not destroy retained resources: {forbidden}")

for token in (
    "const Duration _readerSessionRetentionDuration = Duration(minutes: 2)",
    "const int _maxRetainedReaderSessions = 2",
    "final class _PipelineReaderSessionRetentionPool",
    "session.retainReaderSession()",
    "session.resumeRetainedReaderSession(",
    "Future<void> disposeRetainedSessions()",
    "entry.value.revision",
    "binding?.detach(readerSessionId ?? sessionId)",
    "output._dispose()",
):
    require(session, token, "resource-session retention")
if "identityHashCode(entry.value)" in session:
    raise SystemExit("loader object identity must not defeat same-revision reentry reuse")
for forbidden in (
    "_coordinator.dispose()",
    "_downloads.dispose()",
    "_decodes.dispose()",
    "_streamingSources.dispose()",
    "_media.close()",
):
    retained_body = session.split("void retainReaderSession()", 1)[1].split(
        "void resumeRetainedReaderSession", 1
    )[0]
    if forbidden in retained_body:
        raise SystemExit(f"retention must preserve authoritative resources: {forbidden}")

for token in ("readerSessionRetained", "readerSessionReused"):
    require(trace, token, "Trace lifecycle")
for token in (
    '"readerSessionRetainedCount"',
    '"readerSessionReusedCount"',
    '"readerSessionReuseIdleMicros"',
):
    require(analyzer, token, "Trace analyzer")
for token in (
    "Reader reentry reuses the authoritative resource session",
    "retention keeps the two most recent media-empty Reader sessions",
    "a third retained Reader evicts only the oldest idle session",
    "retainedEvent.payload['ingressProjections'], 0",
    "retainedEvent.payload['streamingSources'], 0",
):
    require(owner_test, token, "owner test")

for production in (native_pool, native_cursor, native_lib, native_header):
    for forbidden in (
        "prepareDecodeThread",
        "zic_prepare_decode_thread",
        "sched_setaffinity",
        "android_performance",
    ):
        if forbidden in production:
            raise SystemExit(f"superseded CPU-affinity path remains: {forbidden}")
if (ROOT / "native/media_core/src/android_performance.rs").exists():
    raise SystemExit("superseded Android affinity source must be deleted")
require(native_pool, "const placementStatus = 0", "stable Trace compatibility")
if "pub const LIB_VERSION: u32 = 0x0012_1400" not in native_lib:
    raise SystemExit("dev.134 native library version missing")
if native_identity != "zic-media-core-dev134-abi6-lib00121400":
    raise SystemExit(f"unexpected dev.134 native identity: {native_identity}")

for token in (
    "BLIT_LANE_COUNT = 1",
    "if (mainHandler.post(::drainProducerSchedules))",
):
    require(kotlin, token, "single-blit presentation retained")
for forbidden in ("makeBackgroundTaskQueue", "postAtFrontOfQueue", "BLIT_LANE_COUNT = 2"):
    if forbidden in kotlin:
        raise SystemExit(f"superseded Android presentation path remains: {forbidden}")

require(check, "test_dev134_reader_resource_session_retention.py", "repository check")
print("dev.134 Reader resource-session retention / affinity removal contract: OK")

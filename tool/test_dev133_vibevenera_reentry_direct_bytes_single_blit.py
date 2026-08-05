#!/usr/bin/env python3
"""Guard dev.133 direct hot bytes and VibeVenera Android presentation threading."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")

manager = read("packages/downloads/lib/src/artifact_cache_manager.dart")
transport = read("packages/downloads/lib/src/artifact_cache_transport.dart")
kotlin = read("packages/texture_bridge/android/src/main/kotlin/dev/zic/texture/TextureBridgePlugin.kt")
download_test = read("packages/downloads/test/artifact_cache_transport_test.dart")
manager_test = read("packages/downloads/test/artifact_cache_manager_test.dart")
android_performance = read("native/media_core/src/android_performance.rs")
native_lib = read("native/media_core/src/lib.rs")
native_identity = read("native/media_core/ANDROID_NATIVE_BUILD_ID").strip()
check = read("tool/check.sh")

for token in (
    "this.memoryMaxEntries = 10",
    "this.memoryMaxBytes = 256 * 1024 * 1024",
):
    if token not in manager:
        raise SystemExit(f"VibeVenera-sized byte window missing: {token}")
for token in (
    "_cache.remember(id: id, bytes: retained, durable: true)",
    "foregroundStartupSegmented: !read.memoryHit",
    "directMemoryBody: read.memoryHit",
    "Stream<List<int>>.value(body)",
    "read.memoryHit ? 'memory-direct' : 'startup-segmented'",
):
    if token not in transport:
        raise SystemExit(f"direct memory ingress contract missing: {token}")
for token in (
    "channel = MethodChannel(",
    "BLIT_LANE_COUNT = 1",
    "return mainHandler.post {",
    "Thread(runnable, \"zic-texture-blit-$index\")",
):
    if token not in kotlin:
        raise SystemExit(f"single-lane platform-channel texture contract missing: {token}")
for token in (
    "gettid()",
    "sched_getaffinity",
    "mask.intersect(&allowed)",
    "sched_setaffinity(tid",
    "setpriority(PRIO_PROCESS",
):
    if token not in android_performance:
        raise SystemExit(f"VibeVenera worker placement contract missing: {token}")
if "pub const LIB_VERSION: u32 = 0x0012_1300" not in native_lib:
    raise SystemExit("dev.133 native library version missing")
if native_identity != "zic-media-core-dev133-abi6-lib00121300":
    raise SystemExit(f"unexpected dev.133 native identity: {native_identity}")
for forbidden in (
    "makeBackgroundTaskQueue",
    "StandardMethodCodec.INSTANCE",
    "postAtFrontOfQueue",
    "BLIT_LANE_COUNT = 2",
):
    if forbidden in kotlin:
        raise SystemExit(f"superseded texture scheduling remains: {forbidden}")
if "completed immutable local origin is hot across Reader sessions" not in download_test:
    raise SystemExit("local direct-memory owner test missing")
if "defaults retain a VibeVenera-sized ten-page byte window" not in manager_test:
    raise SystemExit("default hot-byte window owner test missing")
if "test_dev133_vibevenera_reentry_direct_bytes_single_blit.py" not in check:
    raise SystemExit("repository check does not run dev.133 gate")

print("dev.133 VibeVenera reentry/direct bytes/single blit contract: OK")

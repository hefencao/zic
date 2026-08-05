#!/usr/bin/env python3
"""Guard the dev.132 VibeVenera holder/playback and local hot-byte migration."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
read = lambda path: (ROOT / path).read_text(encoding="utf-8")

upload = read("packages/sessions/lib/src/upload_session.dart")
registry = read("packages/sessions/lib/src/upload_registry.dart")
coordinator = read("packages/sessions/lib/src/live_coordinator.dart")
runtime = read("packages/pipeline_runtime/lib/src/pipeline_reader_session.dart")
pool = read("packages/bridge/lib/src/native_decode_pool.dart")
cursor = read("packages/bridge/lib/src/native_cursor.dart")
transport = read("packages/downloads/lib/src/artifact_cache_transport.dart")
download_test = read("packages/downloads/test/artifact_cache_transport_test.dart")
upload_test = read("packages/sessions/test/upload_session_test.dart")
check = read("tool/check.sh")

for text, forbidden in (
    (upload, "startupBuffering"),
    (upload, "_startupBufferSatisfied"),
    (registry, "isStartupBuffering"),
    (coordinator, "_startupBufferingCurrent"),
    (coordinator, "decode-startup-deferred"),
    (runtime, "_uploads.isStartupBuffering"),
):
    if forbidden in text:
        raise SystemExit(f"startup gate remains after VibeVenera migration: {forbidden}")

for required in (
    "Future<List<_NativeDecodeResult>> decodeBatch",
    "required int maxFrames",
    "for (var index = 0; index < maxFrames; index++)",
):
    if required not in pool:
        raise SystemExit(f"native batch decode contract missing: {required}")
for required in (
    "final Queue<_NativeDecodeResult> _prefetched",
    "maxFrames: _frameCount == 0",
    "? 1",
    ": executionClass == DecodeExecutionClass.current",
    "? 2",
    "void _releasePrefetched()",
):
    if required not in cursor:
        raise SystemExit(f"cursor batch ownership missing: {required}")

for required in (
    "ByteResponse _retainCompletedOrigin",
    "_isImmutableLocalSourceClass(sourceClass)",
    "_cache.remember(id: id, bytes: retained, durable: false)",
):
    if required not in transport:
        raise SystemExit(f"local hot-byte retention missing: {required}")
if "completed immutable local origin is hot across Reader sessions" not in download_test:
    raise SystemExit("downloads owner test for cross-session hot bytes is missing")
if "current animation starts from the visible frame without a startup gate" not in upload_test:
    raise SystemExit("holder-driven playback owner test is missing")
if "test_dev132_vibevenera_holder_playback_local_hot_bytes.py" not in check:
    raise SystemExit("repository check does not run dev.132 gate")

for path in (
    "packages/reader/lib/src/reader_view.dart",
    "packages/reader_runtime/lib/src/reader_runtime_screen.dart",
):
    base = ROOT / path
    files = [base] if base.is_file() else list(base.rglob("*.dart"))
    for file in files:
        text = file.read_text(encoding="utf-8")
        if "ArtifactCacheManager(" in text or "ByteCache" in text:
            raise SystemExit(f"page-byte cache ownership leaked into {file.relative_to(ROOT)}")

print("dev.132 VibeVenera holder playback/local hot bytes contract: OK")

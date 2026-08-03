#!/usr/bin/env python3
"""Guard dev.102 test closure, async texture schedule, and artifact-read lane."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


source_tests = read("apps/app/test/source_browser_test.dart")
for marker in (
    "skip: true); // ZIC-QUARANTINE(Q-001):",
    "skip: true); // ZIC-QUARANTINE(Q-002):",
    "skip: true); // ZIC-QUARANTINE(Q-003):",
):
    if marker not in source_tests:
        raise SystemExit(f"FAIL: source-browser quarantine is not compilable: {marker}")
if "skip: 'ZIC-QUARANTINE" in source_tests:
    raise SystemExit("FAIL: Flutter testWidgets cannot use a String skip reason")

manager = read("packages/downloads/lib/src/artifact_cache_manager.dart")
for token in (
    "readForegroundLookup(",
    "readSessionArtifact(",
    "final running = _inFlight[key]",
    "Future<Uint8List>.sync(loader)",
):
    if token not in manager:
        raise SystemExit(f"FAIL: typed central artifact read bridge missing: {token}")

host = read("packages/pipeline_runtime/lib/src/pipeline_reader_host.dart")
if "unawaited(_disposeSession())" not in host or "await _session.dispose()" not in host:
    raise SystemExit("FAIL: Reader host disposal must use a typed async guard")

kotlin = read(
    "packages/texture_bridge/android/src/main/kotlin/dev/zic/texture/TextureBridgePlugin.kt"
)
for token in (
    "complete: (ScheduleResult) -> Unit",
    "postAtFrontOfQueue",
    "output.present(frameAddress, frameBytes) { presentation ->",
):
    if token not in kotlin:
        raise SystemExit(f"FAIL: async texture schedule contract missing: {token}")
for forbidden in ("CountDownLatch", "completed.await()"):
    if forbidden in kotlin:
        raise SystemExit(f"FAIL: blit lane still blocks platform schedule: {forbidden}")

scheduler = read("packages/downloads/lib/src/artifact_cache_read_scheduler.dart")
for token in (
    "final class ArtifactCacheReadScheduler",
    "this.maxActive = 5",
    "this.foregroundPriority = 900",
    "this.maxBackgroundWhileForeground = 1",
    "_activeBackground < maxBackgroundWhileForeground",
    "void refresh() => _pump()",
    "int get currentPriority => priority()",
):
    if token not in scheduler:
        raise SystemExit(f"FAIL: artifact read scheduler missing: {token}")

runtime = read("packages/pipeline_runtime/lib/src/pipeline_reader_session.dart")
for token in (
    "ArtifactCacheReadScheduler artifactReadScheduler",
    "readScheduler: artifactReadScheduler",
    "demandPriority: _artifactReadPriority",
    "artifactReadScheduler.refresh()",
):
    if token not in runtime:
        raise SystemExit(f"FAIL: process-shared artifact scheduler injection missing: {token}")

transport = read("packages/downloads/lib/src/artifact_cache_transport.dart")
for token in (
    "readSchedulerWaitMicros",
    "priority: priority",
    "scheduler.acquire(priority: priority)",
    "activeLease.priority",
):
    if token not in transport:
        raise SystemExit(f"FAIL: artifact scheduler telemetry missing: {token}")

print("dev.102 async schedule and artifact read ownership: OK")

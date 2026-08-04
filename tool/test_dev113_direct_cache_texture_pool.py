#!/usr/bin/env python3
"""Guard dev.113 direct durable ingress, pooled textures, and source-driven decode wakes."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.113 contract: {token}")

transport = read("packages/transport/lib/src/transport.dart")
cache = read("packages/downloads/lib/src/artifact_cache_manager.dart")
cache_transport = read("packages/downloads/lib/src/artifact_cache_transport.dart")
download = read("packages/sessions/lib/src/download_session.dart")
job = read("packages/sessions/lib/src/download_job.dart")
coordinator = read("packages/sessions/lib/src/live_coordinator.dart")
runtime_api = read("packages/pipeline_runtime/lib/src/pipeline_media_runtime.dart")
reader = read("packages/pipeline_runtime/lib/src/pipeline_reader_session.dart")
native = read("packages/pipeline_native/lib/src/native_pipeline_media_runtime.dart")
texture = read("packages/texture_bridge/lib/src/android_texture_presenter.dart")
analyzer = read("tool/analyze_frame_pipeline_trace.py")
check = read("tool/check.sh")

for token in (
    "enum ByteResponseDisposition",
    "durableImmutable",
    "this.disposition = ByteResponseDisposition.staged",
):
    require(transport, token, "transport response ownership")
for token in (
    "final Set<_ArtifactByteKey> _durableMemory",
    "durable: _durableMemory.contains(key)",
    "remember(id: id, bytes: bytes, durable: true)",
):
    require(cache, token, "artifact cache durability projection")
for token in (
    "ByteResponseDisposition.durableImmutable",
    "disposition: response.disposition",
):
    require(cache_transport, token, "artifact cache transport")
for token in (
    "beginDurableCachedIngress",
    "appendDurableCachedIngress",
    "sealDurableCachedIngress",
    "residentCacheBacked",
    "'cacheResident': true",
):
    require(download, token, "authoritative cache-resident DownloadSession")
for token in (
    "response.disposition == ByteResponseDisposition.durableImmutable",
    "session.appendDurableCachedIngress",
    "await session.reset();",
):
    require(job, token, "direct durable ingress job")
if "session.append(writer, residentOffset" in job:
    raise SystemExit("durable cache responses must not stage through Artifact.append")
for token in (
    "abstract interface class PipelineOutputPrewarmer",
    "prewarmOutput",
):
    require(runtime_api, token, "pipeline media prewarm boundary")
for token in (
    "_AndroidTextureLeasePool",
    "final Set<_TextureSize> _prewarmedSizes",
    "await pool.release(value.lease)",
    "textureLeaseReused",
):
    require(native, token, "composition texture pool")
for token in (
    "prewarmer is PipelineOutputPrewarmer",
    "_prewarmOutput(",
    "'lane': 'output-prewarm'",
):
    require(reader, token, "Reader output prewarm projection")
require(texture, "final bool? leaseReused", "texture telemetry context")
for token in (
    "snapshot.state == DecodeState.waitingSource && !sourceWake",
    "sourceProgressQuantumBytes",
):
    require(coordinator, token, "source-driven decode wake")
for token in (
    '"cacheResidentCommitCount"',
    '"textureLeaseReuseCount"',
):
    require(analyzer, token, "dev.113 trace analyzer")
for path, token in (
    (
        "packages/sessions/test/download_ingress_test.dart",
        "durable cache response seals ingress without staging an artifact",
    ),
    (
        "packages/sessions/test/download_ingress_test.dart",
        "failed durable cache ingress resets the session for retry",
    ),
    (
        "packages/downloads/test/artifact_cache_transport_test.dart",
        "ByteResponseDisposition.durableImmutable",
    ),
):
    require(read(path), token, path)
require(check, "test_dev113_direct_cache_texture_pool.py", "repository check")
print("dev.113 direct cache ingress and texture pool contract: OK")

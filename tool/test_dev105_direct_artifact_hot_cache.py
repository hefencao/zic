#!/usr/bin/env python3
"""Guard dev.105 direct promoted-artifact reads and shared encoded-byte cache."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")

def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.105 contract: {token}")

chapter = read("packages/downloads/lib/src/chapter_downloads.dart")
transport = read("packages/downloads/lib/src/artifact_cache_transport.dart")
cache = read("packages/downloads/lib/src/promoted_artifact_byte_cache.dart")
artifact = read("packages/storage/lib/src/artifact.dart")
pipeline = read("packages/pipeline_runtime/lib/src/pipeline_reader_session.dart")
ephemeral = read("packages/storage/lib/src/ephemeral_workspace.dart")
exports = read("packages/downloads/lib/downloads.dart")
check = read("tool/check.sh")

persistent = chapter[chapter.index("final class PersistentChapterDownloadService"):]
for method in ("readPage(", "readArtifact(", "openArtifactStream("):
    require(persistent, method, "persistent chapter cache")
if "await session.restore" in persistent[persistent.index("Future<Uint8List> readPage"):persistent.index("Future<void> _runDownload")]:
    raise SystemExit("persistent cache reads must not run the full DownloadSession restore chain")
for token in (
    "_promotedArtifactForRead(session)",
    "artifact.restore(verifyPromotedChecksum: false)",
    "readAll: artifact.readBytes",
):
    require(persistent, token, "persistent chapter cache")

for token in (
    "final class PromotedArtifactByteCache",
    "LinkedHashMap<_ArtifactByteKey, Uint8List>",
    "maxEntries = 4",
    "maxBytes = 96 * 1024 * 1024",
    "final running = _inFlight[key]",
    "while (_entries.length > maxEntries || _retainedBytes > maxBytes)",
):
    require(cache, token, "promoted artifact byte cache")

for token in (
    "PromotedArtifactByteCache? byteCache",
    "requestedPriority < foregroundPriority",
    "artifact-byte-cache",
    "artifact-read-all",
    "artifact-cache-read-all",
    "'fallback': 'artifact-cache-stream'",
    "chunkSize: promotedArtifactReadChunkBytes",
):
    require(transport, token, "artifact cache transport")

for token in (
    "import 'dart:isolate';",
    "Isolate.run(() => File(path).readAsBytesSync())",
):
    require(artifact, token, "artifact file reader")

for token in (
    "PromotedArtifactByteCache? artifactByteCache",
    "artifactByteCache ?? PromotedArtifactByteCache()",
    "artifactByteCache: artifactByteCache",
    "final hotBytes = artifactByteCache.lookup(id)",
    "final cacheRead = await artifactByteCache.read(",
):
    require(pipeline, token, "pipeline Reader composition")
require(ephemeral, "artifact.readBytes()", "ephemeral artifact reader")
require(exports, "export 'src/promoted_artifact_byte_cache.dart';", "downloads export")
require(check, "test_dev105_direct_artifact_hot_cache.py", "repository check")

for path in (
    "packages/downloads/test/promoted_artifact_byte_cache_test.dart",
    "docs/adr/0089-direct-promoted-artifact-read-and-hot-cache.md",
    "docs/audits/dev105-direct-artifact-read-cache-audit.md",
):
    if not (ROOT / path).is_file():
        raise SystemExit(f"dev.105 evidence is missing: {path}")

print("dev.105 direct artifact read and hot cache: OK")

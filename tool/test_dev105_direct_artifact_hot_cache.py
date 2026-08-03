#!/usr/bin/env python3
"""Guard retained dev.105 direct reads after cache-manager consolidation."""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
def read(path): return (ROOT / path).read_text(encoding='utf-8')
def require(text, token, owner):
    if token not in text: raise SystemExit(f'{owner} is missing retained dev.105 contract: {token}')
chapter=read('packages/downloads/lib/src/chapter_downloads.dart')
manager=read('packages/downloads/lib/src/artifact_cache_manager.dart')
cache=read('packages/downloads/lib/src/promoted_artifact_byte_cache.dart')
artifact=read('packages/storage/lib/src/artifact.dart')
pipeline=read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
transport=read('packages/downloads/lib/src/artifact_cache_transport.dart')
for token in ('_indexedPromotedArtifact(id)', 'CacheState.ready', 'Isolate.run(() => File(path).readAsBytesSync())'):
    require(chapter, token, 'persistent chapter backend')
for token in ('final class PromotedArtifactByteCache', 'final running = _inFlight[key]', 'maxBytes = 96 * 1024 * 1024'):
    require(cache, token, 'encoded byte tier')
for token in ('final class ArtifactCacheManager', 'readForegroundLookup(', 'readSessionArtifact('):
    require(manager, token, 'artifact cache manager')
for token in ("'artifact-byte-cache'", "'artifact-read-all'", "'fallback': 'artifact-cache-stream'"):
    require(transport, token, 'artifact cache transport')
for token in ('cache?.lookupMemory(id)', 'cache.readSessionArtifact('):
    require(pipeline, token, 'pipeline Reader composition')
for token in ("import 'dart:isolate';", 'Isolate.run(() => File(path).readAsBytesSync())'):
    require(artifact, token, 'artifact file reader')
print('dev.105 direct artifact read and hot cache: OK')

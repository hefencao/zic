#!/usr/bin/env python3
"""Guard retained dev.107 progressive ingress and early handoff lookup."""
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]
def read(path): return (ROOT/path).read_text(encoding='utf-8')
def require(text, token, owner):
    if token not in text: raise SystemExit(f'{owner} is missing retained dev.107 contract: {token}')
manager=read('packages/downloads/lib/src/artifact_cache_manager.dart')
handoff=read('packages/downloads/lib/src/promoted_artifact_cache_handoff.dart')
transport=read('packages/downloads/lib/src/artifact_cache_transport.dart')
pipeline=read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
for token in ('Future<bool> contains(', 'ArtifactCacheTier.memory', 'ArtifactCacheTier.persistent'):
    require(manager, token, 'central cache lookup')
version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
build = int(version.group(1)) if version is not None else 0
presence = 'await cache.containsBackendExact(' if build >= 230 else 'await cache.containsBackend('
for token in (presence, "action: 'skip-existing'", 'final builder = BytesBuilder(copy: false);'):
    require(handoff, token, 'promoted artifact handoff')
if handoff.index(presence) > handoff.index('final builder = BytesBuilder(copy: false);'):
    raise SystemExit('central presence lookup must precede session artifact materialization')
for token in ('foregroundStartupSegmented: !read.memoryHit', 'directMemoryBody: read.memoryHit', "'startup-segmented'", 'await Future<void>.delayed(Duration.zero);'):
    require(transport, token, 'progressive artifact transport')
if build >= 216:
    for token in ('await _coordinator.dispose();', '_transferRuntime.detachPhysicalTrace(', "'coordinatorDisposeMicros': coordinatorDisposeMicros"):
        require(pipeline, token, 'Reader session disposal')
    if '_artifactCacheHandoff?.detach();' in pipeline:
        raise SystemExit('modern Reader disposal must not restore Reader-owned artifact-cache handoff')
else:
    for token in ('_artifactCacheHandoff?.detach();', "'coordinatorDisposeMicros': coordinatorDisposeMicros"):
        require(pipeline, token, 'Reader session disposal')
print('dev.107 reentry progressive handoff: OK')

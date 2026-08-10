#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
DECODE = (ROOT / 'packages/sessions/lib/src/decode_session.dart').read_text()
SESSION = (ROOT / 'packages/sessions/lib/src/download_session.dart').read_text()
LIVE = (ROOT / 'packages/sessions/lib/src/live_coordinator.dart').read_text()
STORE = (ROOT / 'packages/downloads/lib/src/artifact_cache_store.dart').read_text()
MANAGER = (ROOT / 'packages/downloads/lib/src/artifact_cache_manager.dart').read_text()
CHAPTER = (ROOT / 'packages/downloads/lib/src/chapter_downloads.dart').read_text()
HANDOFF = (ROOT / 'packages/downloads/lib/src/partial_artifact_cache_handoff.dart').read_text()
PIPE = (ROOT / 'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart').read_text()
CHAPTER_TEST = (ROOT / 'packages/downloads/test/chapter_downloads_test.dart').read_text()
DECODE_TEST = (ROOT / 'packages/sessions/test/decode_session_test.dart').read_text()
EXPORTS = (ROOT / 'packages/downloads/lib/downloads.dart').read_text()
PUBSPEC = (ROOT / 'apps/app/pubspec.yaml').read_text()
ANDROID = (ROOT / 'apps/app/android/zic-version.properties').read_text()
ARCH = (ROOT / 'docs/ARCHITECTURE.md').read_text()
SPEC = (ROOT / 'docs/SPEC.md').read_text()

restart = DECODE.index("if (_restartCursorWhenHolderEmpty && (_holder?.depth ?? 0) == 0)")
gate = DECODE.index("if (!source.sealed)", restart)
bind = DECODE.index("_cursorCreateMicros = _bind(source, epoch);", gate)
if not restart < gate < bind:
    raise SystemExit('dev.205 cursor restart must precede stale nonsealed prefix gate')
for marker in ("_releaseBinding();", "_restartCursorWhenHolderEmpty = false;"):
    if marker not in DECODE[restart:gate]:
        raise SystemExit(f'dev.205 cursor restart marker missing: {marker}')

for marker in ("Future<DownloadSnapshot> pause(WriterLease lease)", "await artifact.pause()", "CacheState.partial"):
    if marker not in SESSION:
        raise SystemExit(f'dev.205 partial pause marker missing: {marker}')
for marker in ("typedef DownloadPrepare", "this.prepareDownload", "await prepare(session)", "session.committedLength == 0"):
    if marker not in LIVE:
        raise SystemExit(f'dev.205 prepare-download marker missing: {marker}')

for marker in ("final class PartialArtifactCacheEntry", "abstract interface class PartialArtifactCacheBackend"):
    if marker not in STORE:
        raise SystemExit(f'dev.205 partial backend contract missing: {marker}')
for marker in ("supportsPartialArtifacts", "lookupPartial", "storePartialArtifact", "invalidatePartialArtifact"):
    if marker not in MANAGER:
        raise SystemExit(f'dev.205 partial cache manager marker missing: {marker}')
for marker in ("final class PersistentChapterDownloadService", "PartialArtifactCacheBackend", "Future<PartialArtifactCacheEntry?> openPartialArtifact", "await session.pause(writer)"):
    if marker not in CHAPTER:
        raise SystemExit(f'dev.205 chapter durable partial marker missing: {marker}')
memory_block = CHAPTER[CHAPTER.index('final class MemoryChapterDownloadService'):CHAPTER.index('final class PersistentChapterDownloadService')]
if 'PartialArtifactCacheBackend' in memory_block or '_readerPartials' in memory_block:
    raise SystemExit('dev.205 MemoryChapterDownloadService must not grow a duplicate partial tier')
for marker in ("final class PartialArtifactCacheHandoff", "restoreInto(DownloadSession session)", "checkpoint(Iterable<DownloadSession> sessions)", "endExclusive: length"):
    if marker not in HANDOFF:
        raise SystemExit(f'dev.205 handoff marker missing: {marker}')
for marker in ("_partialArtifactCacheHandoff = PartialArtifactCacheHandoff", "prepareDownload: _partialArtifactCacheHandoff?.restoreInto", "_queuePartialArtifactCheckpoint()", "await _partialArtifactCacheHandoff?.drain(_downloads.sessions)"):
    if marker not in PIPE:
        raise SystemExit(f'dev.205 pipeline partial lifecycle marker missing: {marker}')
if "export 'src/partial_artifact_cache_handoff.dart';" not in EXPORTS:
    raise SystemExit('dev.205 handoff export missing')

# Partial is deliberately separate from immutable promoted cache.
if 'PartialArtifactCacheBackend implements ArtifactCacheBackend' in STORE:
    raise SystemExit('dev.205 partial backend must not masquerade as promoted cache backend')
if 'cacheResident = true' in HANDOFF or "'cacheResident': true" in HANDOFF:
    raise SystemExit('dev.205 restored partial must not claim cache-resident promotion')

for marker in (
    'persistent partial artifact survives Reader service reopen without promotion',
    'detached exhausted partial cursor drops stale next-frame prefix gate',
):
    if marker not in CHAPTER_TEST + DECODE_TEST:
        raise SystemExit(f'dev.205 Dart regression contract missing: {marker}')
m = re.search(r'version:\s*0\.31\.0\+(\d+)', PUBSPEC)
if not m or int(m.group(1)) < 205:
    raise SystemExit('dev.205 pubspec version missing')
m = re.search(r'versionCode=(\d+)', ANDROID)
if not m or int(m.group(1)) < 205:
    raise SystemExit('dev.205 Android version missing')

for body, name in ((ARCH,'architecture'), (SPEC,'spec')):
    for marker in ('PartialArtifactCacheBackend', 'frame0', 'HttpURLConnection', 'rhttp'):
        if marker not in body:
            raise SystemExit(f'dev.205 {marker} clarification missing from {name}')
for rel in (
    'docs/adr/0187-durable-reader-partial-handoff-and-cursor-reentry.md',
    'docs/audits/dev205-reader-partial-lifecycle-root-cause-audit.md',
    'docs/audits/dev205-validation-results.md',
):
    if not (ROOT / rel).exists():
        raise SystemExit(f'dev.205 document missing: {rel}')
print('dev.205 durable Reader partial + cursor reentry gate: OK')

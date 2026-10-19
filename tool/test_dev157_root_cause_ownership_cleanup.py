#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f'{owner} missing dev.157 contract: {token}')

def forbid(text: str, token: str, owner: str) -> None:
    if token in text:
        raise SystemExit(f'{owner} retains superseded path: {token}')

catalog_store = read('packages/catalog/lib/src/imported_library_store.dart')
storage_store = read('packages/storage/lib/src/sqlite_imported_library_store.dart')
lazy_store = read('packages/storage/lib/src/lazy_imported_library_store.dart')
writer = read('packages/storage/lib/src/sqlite_progress_writer.dart')
home = read('apps/app/lib/home_shell.dart') + read('apps/app/lib/home_shell_reader_route.dart')
session = read('apps/app/lib/home_library_session.dart')
details = read('apps/app/lib/comic_details.dart')
mihon = read('packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt')
artwork = read('apps/app/lib/artwork_placeholder.dart')
home_widgets = read('apps/app/lib/home_widgets.dart')
views = read('apps/app/lib/home_shell_views.dart')
source_browser = read('apps/app/lib/source_browser.dart')
gateway = read('apps/app/lib/source_resource_gateway.dart')
storage_bridge = read('packages/storage_bridge/lib/storage_bridge.dart')
architecture = read('docs/ARCHITECTURE.md')
spec = read('docs/SPEC.md')
adr = read('docs/archive/adr/0142-reader-checkpoint-mihon-catalog-artwork-presentation-ownership.md')
check = read('tool/check.sh')

# Reader hot path: enqueue only; durable batching belongs to storage isolate.
for token in (
    'abstract interface class ReaderProgressCheckpointStore',
    'void enqueueProgress(ReadingProgress progress);',
    'Future<void> flushProgressCheckpoints();',
):
    require(catalog_store, token, 'Reader checkpoint boundary')
for token in (
    'ReaderProgressCheckpointStore',
    'enqueueProgress(ReadingProgress progress)',
    'Future<void> flushProgressCheckpoints() async',
    'await writer.flush();',
):
    require(storage_store, token, 'SQLite checkpoint implementation')
for token in (
    'ReaderProgressCheckpointStore',
    'final Map<String, ReadingProgress> _pendingReaderProgress',
    'void enqueueProgress(ReadingProgress progress)',
    'Future<void> flushProgressCheckpoints()',
    'Future<void>? _closeFuture;',
    'bool _closing = false;',
    '_flushProgressCheckpoints(allowClosing: true)',
):
    require(lazy_store, token, 'Lazy bootstrap checkpoint implementation')
for token in (
    'Duration(seconds: 8)',
    'Duration(seconds: 30)',
    'idleCommitTimer',
    'maximumCommitTimer',
):
    require(writer, token, 'background WAL batching')
for token in (
    'Future<void> _enqueueReaderProgress(ReadingProgress progress)',
    'enqueueProgress(progress);',
    'ReadingProgress? latestProgress;',
    'latestProgress = progress;',
    '_librarySession.replaceProgress(progress);',
    '_flushReaderProgressCheckpoints()',
    '.flushProgressCheckpoints();',
):
    require(home, token, 'route-local Reader projection')
for stale in ('_saveReaderProgress', '_publishReaderProgressAfterRoute', '_latestReaderProgress'):
    forbid(home, stale, 'superseded global Reader projection')
forbid(home, 'await library.saveProgress(progress)', 'Reader per-page durable barrier')
require(read('docs/archive/adr/0303-reader-progress-durable-exit-barrier.md'), 'Accepted', 'Reader exit durability ADR')
for token in (
    'void replaceProgress(ReadingProgress progress)',
    'Reader page callbacks never call this method',
):
    require(session, token, 'Home one-shot projection')
for token in (
    'typedef ComicDetailsChapterOpener = Future<ReadingProgress?> Function(',
    'List<ImportedLibraryEntry> _replaceChapterProgress(',
):
    require(details, token, 'details local progress projection')
forbid(details, 'reloadLibrary(refreshContent: false)', 'post-Reader full library reload')

# Mihon chapter ownership remains source-defined. The concrete current/legacy
# API ordering is owned by the latest Mihon contract gate rather than frozen in
# this historical dev.157 cleanup test.
for token in (
    'catalog.chapterFailure?.let { throw it }',
    'val existingChapters = cachedMihonChaptersForComic(source, comicId)',
    'loadMihonPageModels(source, chapter, requestId)',
):
    require(mihon, token, 'Mihon chapter catalog ownership')
for stale in (
    'createSyntheticMihonChapter',
    'deduplicateMihonStartReadingEntries',
    'selectMihonChapters(',
    '"开始阅读"',
):
    forbid(mihon, stale, 'Mihon synthetic/title chapter guessing')

# Presentation cannot own automatic recovery. Durable artwork identity is canonical.
for token in (
    'final class StableArtworkImage',
    'required this.source',
    '_provider = encodedResourceImageProvider(widget.source);',
    'if (!identical(oldWidget.source, widget.source))',
):
    require(artwork, token, 'stable artwork widget/provider')
for stale in (
    'ArtworkRetryController',
    'RecoverableArtworkImage',
    '.evict()',
    'Timer(',
):
    forbid(artwork, stale, 'presentation artwork recovery')
for token in (
    'required this.coverIdentity',
    'cacheIdentity: coverIdentity',
):
    require(home_widgets, token, 'Home canonical cover state')
for token in (
    'final coverIdentity = _canonicalComicKey(',
    "'library-list:$coverIdentity'",
    'coverIdentity: coverIdentity',
):
    require(views, token, 'Home list canonical artwork state')
for stale in (
    '_coverSourceInflight',
    '_coverRecoverySourceLoaderForComic',
    '_scheduleFirstFrameWatchdog',
):
    forbid(home + home_widgets, stale, 'duplicate cover owner')
forbid(source_browser, 'ArtworkRetryController', 'source browser timer recovery')
require(details, 'presentationIdentity: widget.artworkIdentity ??', 'details canonical presentation identity')
forbid(gateway, "import 'dart:io';", 'App composition file-system ownership')
require(gateway, 'readEncodedResourceBytes(encoded)', 'storage-owned encoded source materialization')
require(storage_bridge, 'Future<Uint8List> readEncodedResourceBytes(', 'storage bridge encoded source materialization')

for token in (
    'Reader checkpoint',
    'SChapter.url',
    'ComicSourceResourceGateway',
):
    require(architecture + spec + adr, token, 'stable ownership documentation')
require(check, 'test_dev157_root_cause_ownership_cleanup.py', 'repository check integration')

version = re.search(r'^version:\s*\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 157:
    raise SystemExit('App build must be at least 157')
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.157 root-cause ownership cleanup: OK')

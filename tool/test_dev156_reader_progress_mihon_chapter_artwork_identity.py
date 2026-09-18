#!/usr/bin/env python3
"""Current ownership gate for the dev.156 root-cause area."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f"missing {label}: {token}")

def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f"forbidden {label}: {token}")

catalog_store = read("packages/catalog/lib/src/imported_library_store.dart")
sqlite_store = read("packages/storage/lib/src/sqlite_imported_library_store.dart")
lazy_store = read("packages/storage/lib/src/lazy_imported_library_store.dart")
progress_writer = read("packages/storage/lib/src/sqlite_progress_writer.dart")
home = read("apps/app/lib/demo_home.dart") + read("apps/app/lib/demo_home_reader_route.dart")
home_session = read("apps/app/lib/home_library_session.dart")
artwork = read("apps/app/lib/artwork_placeholder.dart")
home_cover = read("apps/app/lib/home_widgets.dart")
gateway = read("apps/app/lib/source_resource_gateway.dart")
cache_identity = read("packages/catalog/lib/src/cache_identity.dart")
mihon = read("packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt")
check = read("tool/check.sh")

for token in (
    "abstract interface class ReaderProgressCheckpointStore",
    "void enqueueProgress(ReadingProgress progress);",
):
    require(catalog_store, token, "Reader checkpoint contract")
forbid(catalog_store, "Future<void> flushProgress();", "Reader route durability barrier")
for token in ("ReaderProgressCheckpointStore", "writer.enqueue(progress);"):
    require(sqlite_store, token, "sqlite progress queue")
for token in (
    "ReaderProgressCheckpointStore",
    "final Map<String, ReadingProgress> _pendingReaderProgress",
    "void enqueueProgress(ReadingProgress progress)",
    "Future<void> flushProgressCheckpoints()",
    "Future<void>? _closeFuture;",
    "bool _closing = false;",
    "_flushProgressCheckpoints(allowClosing: true)",
):
    require(lazy_store, token, "lazy Reader checkpoint handoff")
for token in (
    "Isolate.spawn<List<Object?>>",
    "debugName: 'zic-library-progress'",
    "PRAGMA journal_mode = WAL",
    "final buffered = <String, Map<Object?, Object?>>{}",
):
    require(progress_writer, token, "off-ui latest-wins progress writer")
require(home, "enqueueProgress(progress);", "Reader enqueue")
for token in (
    "ReadingProgress? latestProgress;",
    "return _enqueueReaderProgress(progress);",
    "_librarySession.replaceProgress(progress);",
):
    require(home, token, "route-local post-route memory projection")
forbid(home, "_publishReaderProgressAfterRoute", "superseded global post-route progress")
require(home_session, "void replaceProgress(ReadingProgress progress)", "single Home progress publication")
forbid(home, "_flushReaderProgressAfterRoute", "old route flush")

for token in (
    '"getMangaUpdate",',
    'listOf(manga, existingChapters, true, true)',
    'source.invokeMihonCompatible("fetchChapterList", listOf(manga))',
    'source.invokeMihonCompatible("getPageList", listOf(chapter))',
    'Mihon source exposes no compatible chapter-catalog operation',
):
    require(mihon, token, "Mihon chapter source contract")
for stale in (
    'for (candidate in listOf("getChapterList", "fetchChapterList"))',
    'normalizeMihonChapterCatalog(chapters)',
):
    forbid(mihon, stale, "obsolete Mihon chapter source inference")
for token in (
    "createSyntheticMihonChapter",
    "deduplicateMihonStartReadingEntries",
    "normalizeMihonStartReadingTitle",
    "selectMihonChapters",
    "MIHON_SYNTHETIC_REVISION",
):
    forbid(mihon, token, "guessed Mihon chapter behavior")

for token in (
    "String? cacheComicId,",
    "comicId: cacheComicId ?? comicId,",
    "final cached = forceRefresh",
):
    require(gateway, token, "canonical artwork gateway")
for token in (
    "mutable runtime locator",
    "canonical same-source",
    "must never partition",
):
    require(cache_identity, token, "cache identity documentation")
require(artwork, "final class StableArtworkImage", "single artwork presentation owner")
for token in ("ArtworkRetryController", "RecoverableArtworkImage"):
    forbid(artwork + home_cover, token, "presentation retry owner")

require(check, "test_dev156_reader_progress_mihon_chapter_artwork_identity.py", "check integration")
print("dev.156 reader progress / Mihon chapter / artwork identity: OK")

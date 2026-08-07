#!/usr/bin/env python3
"""Ownership gate for dev.156 root-cause fixes."""

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
progress_writer = read("packages/storage/lib/src/sqlite_progress_writer.dart")
home = read("apps/app/lib/demo_home.dart")
home_session = read("apps/app/lib/home_library_session.dart")
gateway = read("apps/app/lib/source_resource_gateway.dart")
migration = read("apps/app/lib/demo_home_source_migration.dart")
cache_identity = read("packages/catalog/lib/src/cache_identity.dart")
mihon = read(
    "packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt"
)
source_gateway_test = read("apps/app/test/source_resource_gateway_test.dart")
check = read("tool/check.sh")

# Reader progress: durable sqlite work is isolated and per-page callbacks only
# enqueue. The history projection refresh happens after the Reader route returns.
for token in (
    "abstract interface class BufferedReadingProgressStore",
    "void enqueueProgress(ReadingProgress progress);",
    "Future<void> flushProgress();",
):
    require(catalog_store, token, "buffered progress contract")
for token in (
    "BufferedReadingProgressStore",
    "SqliteProgressWriter.open",
    "writer.enqueue(progress);",
    "await _progressWriter?.flush();",
):
    require(sqlite_store, token, "sqlite progress buffering")
for token in (
    "Isolate.spawn<List<Object?>>",
    "debugName: 'zic-library-progress'",
    "'op': 'save'",
    "'op': 'flush'",
    "PRAGMA journal_mode = WAL",
):
    require(progress_writer, token, "off-ui progress writer")
for token in (
    "enqueueProgress(progress);",
    "_flushReaderProgressAfterRoute",
    "await _flushReaderProgressAfterRoute();",
    "await _reloadLibrary();",
):
    require(home, token, "post-route progress projection")
forbid(home, "_librarySession.replaceProgress(progress)", "per-page Home publication")
forbid(home_session, "void replaceProgress(", "Home progress mutation facade")

# Mihon: chapters are source API output. No fabricated SChapter or title-based
# host action inference is allowed.
for token in (
    'Invocation("getMangaUpdate"',
    '"getChapters"',
    'for (candidate in listOf("getChapterList", "fetchChapterList"))',
    '"Mihon chapter catalog failed',
):
    require(mihon, token, "Mihon source chapter contract")
for token in (
    "createSyntheticMihonChapter",
    "deduplicateMihonStartReadingEntries",
    "normalizeMihonStartReadingTitle",
    "selectMihonChapters",
    "MIHON_SYNTHETIC_REVISION",
    '"synthetic"',
):
    forbid(mihon, token, "guessed Mihon chapter behavior")

# Artwork: raw plugin locators and durable cache identities are separate. All
# non-local locators use the one gateway; canonical identity survives raw alias
# changes and source downtime.
for token in (
    "String? cacheComicId,",
    "comicId: cacheComicId ?? comicId,",
    "final cached = forceRefresh",
    "MemoryEncodedResourceSource(:final bytes)",
    "FileEncodedResourceSource(:final path)",
):
    require(gateway, token, "canonical artwork gateway")
for token in (
    "sourceId != 'local-folder' && uri != null",
    "cacheComicId: _canonicalComicId(sourceId, comicId)",
    "comicId: _canonicalComicId(comic.sourceId, comic.comicId)",
):
    require(home, token, "Home/details artwork identity")
require(migration, "cacheComicId: _canonicalComicId(", "migration artwork identity")
for token in (
    "mutable runtime locator",
    "canonical same-source",
    "must never partition",
):
    require(cache_identity, token, "cache identity documentation")
for token in (
    "canonical artwork identity survives mutable raw comic aliases",
    "durable artwork identity bypasses source resolution",
):
    require(source_gateway_test, token, "artwork owner tests")

require(
    check,
    "test_dev156_reader_progress_mihon_chapter_artwork_identity.py",
    "check integration",
)
print("dev.156 reader progress / Mihon chapter / artwork identity: OK")

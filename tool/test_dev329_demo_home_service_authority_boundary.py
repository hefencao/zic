#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(body: str, marker: str, label: str) -> None:
    if marker not in body:
        raise SystemExit(
            f"DemoHome service-authority boundary missing {label}: {marker}"
        )


home = text("apps/app/lib/demo_home.dart")
handoff = text("apps/app/lib/demo_home_service_handoff.dart")
session = text("apps/app/lib/home_library_session.dart")
service_cache = text("apps/app/lib/home_service_cache_binding.dart")

for marker, label in (
    ("ImportedLibraryStore get _library => _librarySession.library;", "library delegation"),
    ("_librarySession.chapterDownloads;", "chapter-download delegation"),
    ("_librarySession.downloadComposition;", "download-composition delegation"),
    ("_librarySession.wholeComicDownloads;", "whole-comic delegation"),
    ("late HomeServiceCacheBinding _serviceCache;", "single cache binding"),
    ("_serviceCache.readerArtifactCache;", "reader cache delegation"),
    ("_serviceCache.coordinator;", "resource cache delegation"),
    ("downloadComposition: downloadComposition,", "initial session composition"),
):
    require(home, marker, label)

for forbidden in (
    "late ImportedLibraryStore _library;",
    "late ChapterDownloadService _chapterDownloads;",
    "late ChapterDownloadTransferRuntimeProvider? _downloadComposition;",
    "late WholeComicDownloadQueue _wholeComicDownloads;",
    "late ArtifactCacheManager? _readerArtifactCache;",
    "late ResourceCacheCoordinator _cacheCoordinator;",
    "late bool _ownsCacheCoordinator;",
    "_library = library;",
    "_chapterDownloads = chapterDownloads;",
    "_downloadComposition = downloadComposition;",
    "_wholeComicDownloads = wholeComicDownloads;",
):
    if forbidden in home or forbidden in handoff:
        raise SystemExit(
            f"DemoHome re-acquired duplicate service authority: {forbidden}"
        )

for marker, label in (
    ("bool _needsDurableServiceAdoption()", "latest service identity check"),
    ("identical(downloadComposition, _downloadComposition)", "composition identity check"),
    ("!identical(suppliedCache, _cacheCoordinator)", "cache identity check"),
    ("if (mounted && _needsDurableServiceAdoption())", "latest-generation drain"),
    ("downloadComposition: downloadComposition,", "handoff session composition"),
    ("wholeComicDownloads.refreshStaleChapter = _refreshStaleQueueChapter;", "queue source refresher"),
    ("identical(_librarySession.downloadComposition, downloadComposition)", "post-adoption authority proof"),
    ("await candidateServiceCache.closeIfOwned();", "rejected candidate cache cleanup"),
    ("_serviceCache = candidateServiceCache;", "cache binding commit"),
    ("await previousServiceCache.closeIfSupersededBy(candidateServiceCache);", "superseded cache cleanup"),
):
    require(handoff, marker, label)

for marker, label in (
    ("final class HomeServiceCacheBinding", "cache binding owner"),
    ("final ResourceCacheCoordinator coordinator;", "coordinator binding"),
    ("final ArtifactCacheManager? readerArtifactCache;", "reader cache binding"),
    ("final bool ownsCoordinator;", "cache ownership bit"),
    ("Future<void> closeIfOwned()", "owned close"),
    ("Future<void> closeIfSupersededBy(HomeServiceCacheBinding next)", "superseded close"),
):
    require(service_cache, marker, label)

require(
    session,
    "if (!_sameSourceInstances(_sources, sources))",
    "same-service source projection refresh",
)
require(
    session,
    "await replaceSources(sources, reloadLibrary: false);",
    "same-service source publication",
)

print("dev.329 DemoHome service authority boundary: OK")

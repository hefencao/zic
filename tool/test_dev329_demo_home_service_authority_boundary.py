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
settings = text("apps/app/lib/app_settings_screen.dart")

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


for marker, label in (
    ("void setChapterDownloadRelay(", "dynamic directory capability publisher"),
    ("chapterDownloadRelay = relay;\n    notifyListeners();", "directory capability invalidation"),
):
    require(session, marker, label)

for marker, label in (
    ("static ChapterDownloadTransferRuntimeProvider? resolveDownloadComposition(", "transfer capability normalizer"),
    ("downloadComposition = resolveDownloadComposition(", "constructor normalization"),
    ("final resolvedDownloadComposition = resolveDownloadComposition(", "adoption normalization"),
    ("ChapterDownloadTransferRuntimeProvider? get _downloadCompositionProvider =>\n      downloadComposition;", "normalized composition authority"),
):
    require(session, marker, label)

for body, path in (
    (home, "apps/app/lib/demo_home.dart"),
    (handoff, "apps/app/lib/demo_home_service_handoff.dart"),
):
    for forbidden in (
        "chapterDownloads is ChapterDownloadTransferRuntimeProvider",
        "chapterDownloads as ChapterDownloadTransferRuntimeProvider",
    ):
        if forbidden in body:
            raise SystemExit(
                f"Home duplicated download-composition normalization in {path}: {forbidden}"
            )
    require(
        body,
        "HomeLibrarySession.resolveDownloadComposition(",
        f"shared composition normalization in {path}",
    )


for marker, label in (
    ("final class DataSettingsRuntimeBinding", "settings runtime capability binding"),
    ("final DataSettingsRuntimeBinding dataRuntime;", "settings runtime binding input"),
    ("final DataSettingsRuntimeBinding runtime;", "data settings runtime binding"),
    ("widget.runtime.clearCache()", "dynamic cache clear dispatch"),
    ("widget.runtime.updateCachePolicyAndTrim(", "dynamic cache maintenance dispatch"),
    ("widget.runtime.readStorageRoot()", "dynamic storage-root projection"),
):
    require(settings, marker, label)

for forbidden in (
    "final ResourceCacheCoordinator cacheCoordinator;",
    "required this.cacheCoordinator",
    "widget.cacheCoordinator",
    "final String? storageRoot;",
    "required this.storageRoot",
    "onChangeChapterDownloadDirectory",
):
    if forbidden in settings:
        raise SystemExit(
            f"Settings re-acquired generation-bound service state: {forbidden}"
        )

for marker, label in (
    ("Future<ResourceCacheUsage> _inspectSettingsCache() async", "dynamic settings cache inspect adapter"),
    ("await _serviceHandoff?.ensureCoreServices?.call();", "explicit cache mutation durable handoff"),
    ("final coordinator = _cacheCoordinator;", "single-operation cache generation capture"),
    ("dataRuntime: DataSettingsRuntimeBinding(", "settings runtime composition wiring"),
    ("readStorageRoot: () => _storageRoot,", "dynamic storage-root wiring"),
    ("clearCache: _clearSettingsCache,", "dynamic clear wiring"),
    ("updateCachePolicyAndTrim: _updateSettingsCachePolicyAndTrim,", "dynamic trim wiring"),
):
    require(home, marker, label)

inspect_start = home.index("Future<ResourceCacheUsage> _inspectSettingsCache() async")
clear_start = home.index("Future<DataSettingsCacheMutationResult> _clearSettingsCache() async")
trim_start = home.index("Future<DataSettingsCacheMutationResult> _updateSettingsCachePolicyAndTrim(")
directory_start = home.index("Future<String?> _changeSettingsChapterDownloadDirectory(")
inspect_body = home[inspect_start:clear_start]
clear_body = home[clear_start:trim_start]
trim_body = home[trim_start:directory_start]
if "ensureCoreServices" in inspect_body:
    raise SystemExit(
        "Settings cache inspect must not force empty-install durable core services"
    )
for body, label in (
    (clear_body, "settings cache clear"),
    (trim_body, "settings cache trim"),
):
    require(body, "await _serviceHandoff?.ensureCoreServices?.call();", f"{label} durable handoff")
    require(body, "await _adoptDurableServices();", f"{label} current-generation adoption")
    require(body, "final coordinator = _cacheCoordinator;", f"{label} one-generation capture")

close_body = session[session.index('Future<void> _closeOwnedResources() async {'):]
for marker, label in (
    ('await flushSnapshotWrites();', 'snapshot tail drain before owner close'),
    ('_closed = true;', 'closed publication after drains'),
):
    require(close_body, marker, label)
if close_body.index('await flushSnapshotWrites();') > close_body.index('_closed = true;'):
    raise SystemExit('Home session must drain admitted snapshots before publishing closed')

dispose_start = home.index('  @override\n  void dispose() {')
close_composition_start = home.index('  Future<void> _closeHomeComposition() async {', dispose_start)
dispose_body = home[dispose_start:close_composition_start]
if '_librarySession.dispose();' in dispose_body:
    raise SystemExit('DemoHome State.dispose must not synchronously dispose a closing Home session')
close_composition_body = home[close_composition_start:]
for marker, label in (
    ('await _librarySession.close();', 'async session close'),
    ('_librarySession.dispose();', 'post-close notifier disposal'),
):
    require(close_composition_body, marker, label)
if close_composition_body.index('await _librarySession.close();') > close_composition_body.index(
    '_librarySession.dispose();'
):
    raise SystemExit('Home session notifier disposal must follow async owner close')

print("dev.329 DemoHome service authority boundary: OK")

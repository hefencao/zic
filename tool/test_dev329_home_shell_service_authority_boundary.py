#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(body: str, marker: str, label: str) -> None:
    if marker not in body:
        raise SystemExit(
            f"HomeShell service-authority boundary missing {label}: {marker}"
        )


home = text("apps/app/lib/home_shell.dart") + text("apps/app/lib/home_shell_sync.dart")
home_views = text("apps/app/lib/home_shell_views.dart")
handoff = text("apps/app/lib/home_shell_service_handoff.dart")
source_migration = text("apps/app/lib/home_shell_source_migration.dart")
session = text("apps/app/lib/home_library_session.dart")
service_cache = text("apps/app/lib/home_service_cache_binding.dart")
adoption = text("apps/app/lib/home_service_adoption.dart")
settings = text("apps/app/lib/app_settings_screen.dart")
lazy_store = text("packages/storage/lib/src/lazy_imported_library_store.dart")

for marker, label in (
    ("ImportedLibraryStore get _library => _librarySession.library;", "library delegation"),
    ("_librarySession.chapterDownloads;", "chapter-download delegation"),
    ("_librarySession.downloadComposition;", "download-composition delegation"),
    ("_librarySession.wholeComicDownloads;", "whole-comic delegation"),
    ("late final HomeServiceAdoptionCoordinator _serviceAdoption;", "service adoption owner"),
    ("_serviceAdoption.readerArtifactCache;", "reader cache delegation"),
    ("_serviceAdoption.cacheCoordinator;", "resource cache delegation"),
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
            f"HomeShell re-acquired duplicate service authority: {forbidden}"
        )

for marker, label in (
    ("final class HomeServiceAdoptionCoordinator", "standalone adoption owner"),
    ("bool needsCurrentAdoption()", "latest service identity check"),
    ("identical(downloadComposition, session.downloadComposition)", "composition identity check"),
    ("!identical(suppliedCache, cacheCoordinator)", "cache identity check"),
    ("if (!_closing &&", "bounded latest-generation drain"),
    ("final superseded = !identical(library, libraryProvider())", "failed-generation replacement check"),
    ("unawaited(adoptCurrent().catchError", "background failure observation"),
    ("Error.throwWithStackTrace(adoptionError, adoptionStack!)", "explicit handoff failure propagation"),
    ("downloadComposition: downloadComposition,", "handoff session composition"),
    ("wholeComicDownloads.refreshStaleChapter = refreshStaleChapter;", "queue source refresher"),
    ("identical(session.downloadComposition, downloadComposition)", "post-adoption authority proof"),
    ("await candidateCacheBinding.closeIfOwned();", "rejected candidate cache cleanup"),
    ("_cacheBinding = candidateCacheBinding;", "cache binding commit"),
    ("await previousCacheBinding.closeIfSupersededBy(candidateCacheBinding);", "superseded cache cleanup"),
    ("externalPluginLoaderAvailable()", "deferred plugin loader handoff"),
    ("void beginClose()", "close admission fence"),
):
    require(adoption, marker, label)

for forbidden in ("BuildContext", "Navigator", "State<", "Widget", "mounted", "setState("):
    if forbidden in adoption:
        raise SystemExit(
            f"HomeServiceAdoptionCoordinator acquired UI authority: {forbidden}"
        )

for marker, label in (
    ("_serviceAdoption.startCurrentAdoption();", "handoff adoption trigger"),
    ("_externalSources.adoptController(plugins);", "external controller handoff"),
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
    "await _replaceSources(sources, reloadLibrary: false);",
    "same-service source publication through pre-admitted continuation",
)

for marker, label in (
    ("Future<void>? _libraryReload;", "reload/adoption admission tail"),
    ("Future<void> _runLibraryReload({", "reload admission owner"),
    ("final adoptionAtAdmission = _serviceAdoption;", "adoption-before-reload ordering"),
    ("final reloadAtAdmission = _libraryReload;", "reload-before-adoption ordering"),
    ("openLibrary: true,", "retry/ensureReady open inside reload admission"),
    ("final projectionChangedAtPublish =", "final reload projection revision revalidation"),
    ("_categories = projectionChangedAtPublish", "concurrent category projection preservation"),
    ("...seedPreferences, ..._preferences", "current comic preference wins stale reload"),
    ("...sourcePreferences,", "reload source preference defaults merge"),
    ("..._sourcePreferences,", "current source preference wins stale reload"),
    ("_activeSourceId = _activeSourceIdFor(", "active source final-map recompute"),
    ("_persistStableLibraryMutationResult<T>(", "stable library mutation result owner"),
    ("Future<ImportedLibraryStore> _persistStableLibraryMutation(", "stable library mutation owner"),
    ("Future<void> persistPreferences(", "comic preference mutation owner"),
    ("Future<void> persistSourcePreference(", "source preference mutation owner"),
    ("Future<void> persistReadState(", "read-state mutation owner"),
    ("Future<void> upsertCategory(", "category upsert owner"),
    ("await store.upsertCategory(category);", "category same-store write"),
    ("final categories = await store.listCategories();", "category same-store readback"),
    ("Future<void> removeCategory(String categoryId) =>", "category removal owner"),
    ("await store.removeCategory(categoryId);", "category removal same-store write"),
    ("categories: await store.listCategories(),", "category removal category readback"),
    ("preferences: await store.listComicPreferences(),", "category removal cascade readback"),
    ("Future<ImportedLibraryEntry> upsertChapter(", "chapter write-through owner"),
    ("await store.upsertChapter(chapter);", "chapter same-store write"),
    ("return store.get(chapter.sourceId, chapter.chapterId);", "chapter same-store readback"),
    ("Future<void> upsertSavedComic(", "saved-comic write-through owner"),
    ("return store.getSavedComic(comic.sourceId, comic.comicId);", "saved-comic same-store readback"),
    ("Future<void> persistProgress(ReadingProgress progress) =>", "non-Reader progress mutation owner"),
    ("(store) => store.saveProgress(progress),", "non-Reader progress stable write"),
    ("Future<ImportedLibraryEntry> hydrateEntry(", "hydration admission entry"),
    ("() => _hydrateEntry(", "hydration private continuation"),
    ("Future<Map<String, ImportedLibraryEntry>> hydrateChapterBatch(", "batch hydration admission entry"),
    ("() => _hydrateChapterBatch(chapters)", "batch hydration private continuation"),
    ("Future<void> ensureCanonicalMediaForEntry(", "canonical hydration admission entry"),
    ("_runAdmittedOperation(() => _ensureCanonicalMediaForEntry(entry))", "canonical private continuation"),
):
    require(session, marker, label)

source_default_start = session.index("final sourceDefaultsClock = Stopwatch()..start();")
source_default_end = session.index(
    "'source-preferences-defaults-complete '",
    source_default_start,
)
comic_default_start = session.index("final comicDefaultsClock = Stopwatch()..start();")
comic_default_end = session.index(
    "'comic-preferences-defaults-complete '",
    comic_default_start,
)
for body, label in (
    (
        session[source_default_start:source_default_end],
        "source preference synthesized default",
    ),
    (
        session[comic_default_start:comic_default_end],
        "comic preference synthesized default",
    ),
):
    if "updatedAt:" in body:
        raise SystemExit(
            f"{label} must keep its factory baseline timestamp, not claim user-update recency"
        )

for forbidden in (
    "await library.upsertChapter(",
    "await library.removeChapter(",
    "await library.upsertSavedComic(",
    "await library.removeSavedComic(",
    "await library.saveProgress(",
):
    if forbidden in session:
        raise SystemExit(
            f"HomeLibrarySession bypasses stable library mutation owner: {forbidden}"
        )

for marker, label in (
    ("(library as ReaderProgressCheckpointStore).enqueueProgress(progress);", "Reader checkpoint enqueue"),
    ("unawaited(library.saveProgress(progress));", "Reader compatibility non-blocking progress write"),
):
    require(home, marker, label)
for marker, label in (
    ("ReaderProgressCheckpointStore,", "Lazy bootstrap Reader checkpoint capability"),
    ("final Map<String, ReadingProgress> _pendingReaderProgress", "Lazy pending checkpoint owner"),
    ("Future<void> flushProgressCheckpoints()", "Lazy checkpoint flush barrier"),
    ("Future<void>? _closeFuture;", "Lazy joinable close owner"),
    ("bool _closing = false;", "Lazy close admission fence"),
):
    require(lazy_store, marker, label)
for forbidden in ("_pendingReaderProgress", "_readerProgressForwarding"):
    if forbidden in home:
        raise SystemExit(
            f"HomeShell acquired Lazy Reader checkpoint forwarding state: {forbidden}"
        )

reader_progress_start = home.index("Future<void> _enqueueReaderProgress(ReadingProgress progress)")
reader_progress_end = home.index("Future<void> _flushReaderProgressCheckpoints()", reader_progress_start)
reader_progress_body = home[reader_progress_start:reader_progress_end]
if "_librarySession.persistProgress(" in reader_progress_body:
    raise SystemExit(
        "Reader progress callback must not await ordinary HomeLibrarySession durable mutation"
    )

for marker, label in (
    ("_librarySession.upsertCategory(category);", "category upsert delegation"),
    ("_librarySession.removeCategory(category.categoryId);", "category removal delegation"),
):
    require(home_views, marker, label)
for marker, label in (
    ("_librarySession.persistPreferences(updatedPreferences);", "comic preference delegation"),
    ("_librarySession.persistSourcePreference(updated);", "source preference delegation"),
    ("_librarySession.persistReadState(state);", "read-state delegation"),
    ("_librarySession.persistPreferences(reorderedPreferences);", "batch reorder delegation"),
):
    require(home, marker, label)

for forbidden in (
    "_library.saveComicPreference(",
    "_library.saveSourcePreference(",
    "_library.saveChapterReadState(",
    "_library.upsertCategory(",
    "_library.removeCategory(",
    "_librarySession.replacePreference(",
    "_librarySession.replaceSourcePreference(",
    "_librarySession.replaceReadState(",
):
    if forbidden in home or forbidden in home_views:
        raise SystemExit(
            f"HomeShell bypasses HomeLibrarySession library mutation owner: {forbidden}"
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
    (home, "apps/app/lib/home_shell.dart"),
    (adoption, "apps/app/lib/home_service_adoption.dart"),
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
    require(body, "await _serviceAdoption.adoptCurrent();", f"{label} current-generation adoption")
    require(body, "final coordinator = _cacheCoordinator;", f"{label} one-generation capture")

for marker, label in (
    ('StateError? _admissionError()', 'session close admission fence helper'),
    ('if (_closing != null || _closed)', 'closing-or-closed admission condition'),
    ('Future<T> _runAdmittedOperation<T>(', 'public operation admission owner'),
    ('Future<void> _drainAdmittedOperations()', 'admitted operation drain'),
    ('_activeAdmissions++;', 'admitted operation count'),
    ('_activeAdmissions--;', 'admitted operation release'),
):
    require(session, marker, label)

for signature, label in (
    ('Future<void> reload({bool waitForOpen = true}) =>', 'reload admission'),
    ('Future<void> adoptServices({', 'service adoption admission'),
    ('Future<void> ensureReady() =>', 'ensureReady admission'),
    ('Future<void> retry() =>', 'retry admission'),
    ('Future<void> upsertVersionRelation(ComicVersionRelation relation) =>', 'version relation admission'),
    ('Future<void> replaceSources(', 'source projection admission'),
    ('Future<void> persistPreferences(', 'preference mutation admission'),
    ('Future<ImportedLibraryEntry> upsertChapter(', 'chapter mutation admission'),
):
    start = session.index(signature)
    body = session[start:start + 700]
    require(body, '_runAdmittedOperation', label)

stable_mutation_start = session.index(
    'Future<({ImportedLibraryStore store, T value})>'
)
stable_mutation_end = session.index(
    'Future<ImportedLibraryStore> _persistStableLibraryMutation(',
    stable_mutation_start,
)
if '_requireAdmissionOpen();' in session[stable_mutation_start:stable_mutation_end]:
    raise SystemExit(
        'pre-admitted stable library mutation must not re-check close admission'
    )

require(
    session,
    'await _replaceSources(sources, reloadLibrary: false);',
    'pre-admitted adoption private source continuation',
)

close_body = session[session.index('Future<void> _closeOwnedResources() async {'):]
for marker, label in (
    ('await _ready;', 'constructor initialization drain'),
    ('await _drainAdmittedOperations();', 'public operation drain'),
    ('await flushSnapshotWrites();', 'snapshot tail drain before owner close'),
    ('_closed = true;', 'closed publication after drains'),
):
    require(close_body, marker, label)
for earlier, later, label in (
    ('await _ready;', 'await _drainAdmittedOperations();', 'initialize before public drain'),
    ('await _drainAdmittedOperations();', 'await flushSnapshotWrites();', 'public operations before snapshot drain'),
    ('await flushSnapshotWrites();', '_closed = true;', 'snapshot drain before closed publication'),
):
    if close_body.index(earlier) > close_body.index(later):
        raise SystemExit(f'Home session close ordering regressed: {label}')

dispose_start = home.index('  @override\n  void dispose() {')
close_composition_start = home.index('  Future<void> _closeHomeComposition() async {', dispose_start)
dispose_body = home[dispose_start:close_composition_start]
if '_librarySession.dispose();' in dispose_body:
    raise SystemExit('HomeShell State.dispose must not synchronously dispose a closing Home session')
require(dispose_body, '_serviceAdoption.beginClose();', 'service adoption close fence')
close_composition_body = home[close_composition_start:]
for marker, label in (
    ('late final HomeServiceAdoptionCoordinator _serviceAdoption;', 'durable adoption collaborator'),
    ('Future<void>? _sourceMigrationRecovery;', 'source migration recovery tail'),
):
    require(home, marker, label)
for marker, label in (
    ('await _drainHomeCompositionTail(\n      _serviceAdoption.activeAdoption,', 'durable adoption teardown drain'),
    ('await _drainHomeCompositionTail(\n      _sourceMigrationRecovery,', 'source migration teardown drain'),
    ('await _readerChapterComposition.close();', 'Reader chapter composition teardown drain'),
    ('await _versionReuseLifecycle.close();', 'version reuse lifecycle teardown drain'),
    ('await _externalSources.close();', 'external lifecycle close after composition tails'),
    ('await _librarySession.close();', 'async session close'),
    ('_librarySession.dispose();', 'post-close notifier disposal'),
):
    require(close_composition_body, marker, label)
if close_composition_body.index('await _librarySession.close();') > close_composition_body.index(
    '_librarySession.dispose();'
):
    raise SystemExit('Home session notifier disposal must follow async owner close')
for earlier, later, label in (
    ('_serviceAdoption.activeAdoption,', '_sourceMigrationRecovery,', 'durable adoption before migration recovery'),
    ('_sourceMigrationRecovery,', 'await _readerChapterComposition.close();', 'composition recovery before Reader composition close'),
    ('await _readerChapterComposition.close();', 'await _versionReuseLifecycle.close();', 'Reader composition before version lifecycle close'),
    ('await _versionReuseLifecycle.close();', 'await _externalSources.close();', 'version lifecycle before external close'),
    ('await _externalSources.close();', 'await _librarySession.close();', 'external lifecycle before session close'),
    ('await _librarySession.close();', '_sourceResources.close();', 'session close before source-resource close'),
    ('_sourceResources.close();', 'await _serviceAdoption.closeCacheIfOwned();', 'source-resource close before cache close'),
):
    if close_composition_body.index(earlier) > close_composition_body.index(later):
        raise SystemExit(f'Home composition teardown ordering regressed: {label}')

for marker, label in (
    ('Future<void> _recoverCommittedSourceMigrations() {', 'source migration recovery single-flight entry'),
    ('final existing = _sourceMigrationRecovery;', 'source migration current tail lookup'),
    ('if (existing != null) return existing;', 'source migration recovery join'),
    ('_sourceMigrationRecovery = recovery;', 'source migration tail publication'),
    ('if (identical(_sourceMigrationRecovery, recovery))', 'source migration exact tail cleanup'),
    ('Future<void> _recoverCommittedSourceMigrationsOnce() async {', 'source migration private recovery continuation'),
):
    require(source_migration, marker, label)

print("dev.329 HomeShell service authority boundary: OK")

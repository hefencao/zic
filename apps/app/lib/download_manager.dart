import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:resource_cache/resource_cache.dart';

import 'package:downloads/downloads.dart';
import 'package:telemetry/telemetry.dart';

import 'dialog_actions.dart';

const downloadManagerScreenKey = ValueKey<String>('download-manager-screen');
const downloadManagerRefreshKey = ValueKey<String>('download-manager-refresh');
const downloadQueuePolicyKey = ValueKey<String>('download-queue-policy');
const downloadCacheTrimKey = ValueKey<String>('download-cache-trim');
const downloadCacheClearKey = ValueKey<String>('download-cache-clear');
const downloadManagerTabManualKey = ValueKey<String>('download-tab-manual');
const downloadManagerTabCacheKey = ValueKey<String>('download-tab-cache');
const downloadManagerBottomNavKey = ValueKey<String>('download-manager-bottom-nav');

Key downloadManagerTaskKey(String identity) =>
    ValueKey<String>('download-task:$identity');
Key downloadManagerAutoCacheTaskKey(String identity) =>
    ValueKey<String>('auto-cache-task:$identity');
Key downloadManagerCanonicalCacheTaskKey(String identity) =>
    ValueKey<String>('canonical-cache-task:$identity');
Key downloadManagerCancelKey(String identity) =>
    ValueKey<String>('download-cancel:$identity');
Key downloadManagerRetryKey(String identity) =>
    ValueKey<String>('download-retry:$identity');
Key downloadManagerConvertKey(String identity) =>
    ValueKey<String>('download-convert:$identity');
Key downloadManagerClearCacheKey(String identity) =>
    ValueKey<String>('download-clear-cache:$identity');
Key downloadManagerDeleteKey(String identity) =>
    ValueKey<String>('download-delete:$identity');
Key downloadManagerCopyErrorKey(String identity) =>
    ValueKey<String>('download-copy-error:$identity');
Key wholeComicQueueJobKey(String jobId) =>
    ValueKey<String>('whole-comic-queue-job:$jobId');
Key wholeComicQueuePauseKey(String jobId) =>
    ValueKey<String>('whole-comic-queue-pause:$jobId');
Key wholeComicQueueResumeKey(String jobId) =>
    ValueKey<String>('whole-comic-queue-resume:$jobId');
Key wholeComicQueueCancelKey(String jobId) =>
    ValueKey<String>('whole-comic-queue-cancel:$jobId');
Key wholeComicQueueRetryKey(String jobId) =>
    ValueKey<String>('whole-comic-queue-retry:$jobId');
Key wholeComicQueueRemoveKey(String jobId) =>
    ValueKey<String>('whole-comic-queue-remove:$jobId');

enum DownloadManagerTab {
  manual,
  autoCache,
}

final class DownloadManagerServices {
  const DownloadManagerServices({
    required this.downloads,
    required this.wholeComicDownloads,
    this.cacheCoordinator,
  });

  final ChapterDownloadService downloads;
  final WholeComicDownloadQueue wholeComicDownloads;
  final ResourceCacheCoordinator? cacheCoordinator;
}


final class DownloadManagerProjection {
  const DownloadManagerProjection({
    required this.entries,
    required this.snapshots,
    required this.wholeComicSnapshot,
    this.cacheProjection,
    this.versionBaselines = ComicVersionBaselineProjection.empty,
  });

  final List<ImportedLibraryEntry> entries;
  final List<ChapterDownloadSnapshot> snapshots;
  final WholeComicQueueSnapshot wholeComicSnapshot;
  final ChapterCacheManagementProjection? cacheProjection;
  final ComicVersionBaselineProjection versionBaselines;
}


final class _DownloadVersionBaselineIndex {
  _DownloadVersionBaselineIndex(this._projection) {
    for (final relation in _projection.downloadHeadRelations) {
      _directByMember[
        _comicKey(relation.sourceId, relation.predecessorComicId)
      ] = relation;
    }
  }

  final ComicVersionBaselineProjection _projection;
  final Map<String, ComicVersionRelation> _directByMember =
      <String, ComicVersionRelation>{};

  static String _comicKey(String sourceId, String comicId) =>
      '$sourceId\u0000$comicId';

  String chapterBaselineKey(
    String sourceId,
    String comicId,
    String chapterId,
  ) {
    final head = _projection.downloadHeadFor(sourceId, comicId);
    if (head == null) {
      return '$sourceId\u0000$comicId\u0000$chapterId';
    }
    if (comicId == head) {
      return '$sourceId\u0000$head\u0000$chapterId';
    }
    final direct = _directByMember[_comicKey(sourceId, comicId)];
    if (direct == null || direct.successorComicId != head) {
      // The historical path was ambiguous or could not be composed. Keep the
      // old task exact rather than teaching Presentation to traverse history.
      return '$sourceId\u0000$comicId\u0000$chapterId';
    }
    if (direct.pageMappings.isEmpty) {
      // Compatibility for legacy version relations that predate chapter
      // mappings: same raw chapter id is the only allowed fallback.
      return '$sourceId\u0000$head\u0000$chapterId';
    }
    for (final mapping in direct.pageMappings) {
      if (mapping.predecessorChapterId == chapterId) {
        return '$sourceId\u0000$head\u0000${mapping.successorChapterId}';
      }
    }
    return '$sourceId\u0000$comicId\u0000$chapterId';
  }

  bool isDownloadHead(ChapterDownloadSnapshot snapshot) =>
      _projection.downloadHeadFor(snapshot.sourceId, snapshot.comicId) ==
          snapshot.comicId;

  String? preferredCanonicalComicId(String sourceId, String comicId) {
    final family = _projection.familyFor(sourceId, comicId);
    return family?.shelfHeadComicId ??
        family?.latestKnownComicId ??
        family?.downloadHeadComicId;
  }
}


final class DownloadManagerScreen extends StatefulWidget {
  const DownloadManagerScreen({
    required this.entries,
    required this.downloads,
    required this.wholeComicDownloads,
    this.initialSnapshots = const <ChapterDownloadSnapshot>[],
    this.initialWholeComicSnapshot,
    this.initialCacheProjection,
    this.cacheCoordinator,
    this.hydrateEntry,
    this.loadAllEntries,
    this.resolveServices,
    this.projectionChanges,
    this.readProjection,
    this.refreshProjection,
    this.traceSink = const NoopTraceSink(),
    this.versionBaselines = ComicVersionBaselineProjection.empty,
    super.key,
  });

  final List<ImportedLibraryEntry> entries;
  final ChapterDownloadService downloads;
  final TraceSink traceSink;
  final WholeComicDownloadQueue wholeComicDownloads;
  final List<ChapterDownloadSnapshot> initialSnapshots;
  final WholeComicQueueSnapshot? initialWholeComicSnapshot;
  final ChapterCacheManagementProjection? initialCacheProjection;
  final ResourceCacheCoordinator? cacheCoordinator;
  final Future<ImportedLibraryEntry> Function(ImportedLibraryEntry)? hydrateEntry;
  final Future<List<ImportedLibraryEntry>> Function()? loadAllEntries;
  final Future<DownloadManagerServices> Function()? resolveServices;
  final Listenable? projectionChanges;
  final DownloadManagerProjection Function()? readProjection;
  final Future<void> Function()? refreshProjection;
  final ComicVersionBaselineProjection versionBaselines;

  @override
  State<DownloadManagerScreen> createState() => _DownloadManagerScreenState();
}

final class _DownloadManagerScreenState extends State<DownloadManagerScreen> {
  final Map<String, ImportedLibraryEntry> _entries =
      <String, ImportedLibraryEntry>{};
  final Map<String, String> _entryIdentityByChapter = <String, String>{};
  final Map<String, ChapterDownloadSnapshot> _snapshots =
      <String, ChapterDownloadSnapshot>{};
  StreamSubscription<ChapterDownloadSnapshot>? _subscription;
  StreamSubscription<void>? _managementProjectionSubscription;
  StreamSubscription<WholeComicQueueSnapshot>? _wholeComicSubscription;
  Timer? _managementProjectionRefreshTimer;
  Future<void>? _managementProjectionRefresh;
  bool _managementProjectionRefreshPending = false;
  late ChapterDownloadService _downloads;
  late WholeComicDownloadQueue _wholeComicDownloads;
  ResourceCacheCoordinator? _cacheCoordinator;
  late WholeComicQueueSnapshot _wholeComicSnapshot;
  Future<void>? _servicesResolution;
  Future<void>? _cacheUsageRefresh;
  ResourceCacheCoordinator? _cacheUsageRefreshCoordinator;
  bool _servicesResolved = false;
  bool _loading = false;
  bool _cacheBusy = false;
  ResourceCacheUsage? _cacheUsage;
  ChapterCacheManagementProjection? _cacheProjection;
  DownloadManagerTab _selectedTab = DownloadManagerTab.manual;
  _DownloadVersionBaselineIndex _versionBaselines =
      _DownloadVersionBaselineIndex(ComicVersionBaselineProjection.empty);

  final MonoClock _traceClock = const SystemClock();
  late final int _openedAtMicros;

  void _recordTrace(String stage, {Map<String, Object?> payload = const {}}) {
    try {
      widget.traceSink.record(
        traceEvent(
          clock: _traceClock,
          sessionId: 'download-manager',
          kind: TraceEventKind.downloadState,
          payload: <String, Object?>{
            'stage': stage,
            'routeElapsedUs': _traceClock.nowMicros() - _openedAtMicros,
            ...payload,
          },
        ),
      );
    } on Object {
      // Diagnostics must never affect the download manager route.
    }
  }

  void _rememberEntry(ImportedLibraryEntry entry) {
    final identity = _identity(entry);
    _entries[identity] = entry;
    _entryIdentityByChapter.putIfAbsent(
      _chapterIdentity(
        entry.chapter.sourceId,
        entry.chapter.comicId,
        entry.chapter.chapterId,
      ),
      () => identity,
    );
  }

  void _replaceEntries(Iterable<ImportedLibraryEntry> entries) {
    _entries.clear();
    _entryIdentityByChapter.clear();
    for (final entry in entries) {
      _rememberEntry(entry);
    }
  }

  String _matchingEntryIdentity(ChapterDownloadSnapshot snapshot) =>
      _entryIdentityByChapter[
        _chapterIdentity(
          snapshot.sourceId,
          snapshot.comicId,
          snapshot.chapterId,
        )
      ] ??
      snapshot.identity;

  /// In-flight action locks, keyed by `task identity:action` and taken
  /// synchronously in the tap handler. Keys are per ACTION, not per task:
  /// an identity-wide lock used to swallow the stop tap for as long as a
  /// retry kept running, which forced users to leave and reopen this page
  /// just to stop a download.
  final Set<String> _busyActionKeys = <String>{};

  bool _isActionBusy(String identity, String actionKey) =>
      _busyActionKeys.contains('$identity:$actionKey');

  @override
  void initState() {
    super.initState();
    _openedAtMicros = _traceClock.nowMicros();
    _recordTrace('manager-init');
    _downloads = widget.downloads;
    _wholeComicDownloads = widget.wholeComicDownloads;
    _cacheCoordinator = widget.cacheCoordinator;
    _versionBaselines = _DownloadVersionBaselineIndex(widget.versionBaselines);
    _cacheProjection = widget.initialCacheProjection;
    _replaceEntries(widget.entries);
    for (final snapshot in widget.initialSnapshots) {
      final matchingKey = _matchingEntryIdentity(snapshot);
      if (_entries.containsKey(matchingKey)) {
        _snapshots[matchingKey] = snapshot;
      }
    }
    _subscription = _listenToDownloads(_downloads);
    _managementProjectionSubscription =
        _listenToManagementProjectionChanges(_downloads);
    _wholeComicSnapshot =
        widget.initialWholeComicSnapshot ?? _wholeComicDownloads.snapshot;
    _wholeComicSubscription = _listenToWholeComicDownloads(
      _wholeComicDownloads,
    );
    widget.projectionChanges?.addListener(_handleProjectionChanged);
    // Route-first ownership: the download screen must paint from the already
    // projected Home/queue snapshot before any durable/cache inspection starts.
    // Microtasks run before the next frame, so doing filesystem-backed
    // inspection here makes the previous Home route appear stuck after tap.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _recordTrace('manager-first-frame');
      unawaited(_refreshAfterFirstFrame());
    });
  }

  @override
  void dispose() {
    widget.projectionChanges?.removeListener(_handleProjectionChanged);
    _managementProjectionRefreshTimer?.cancel();
    unawaited(_subscription?.cancel());
    unawaited(_managementProjectionSubscription?.cancel());
    unawaited(_wholeComicSubscription?.cancel());
    super.dispose();
  }

  Future<void> _resolveServices() {
    if (_servicesResolved || widget.resolveServices == null) {
      return Future<void>.value();
    }
    final existing = _servicesResolution;
    if (existing != null) {
      return existing;
    }
    late final Future<void> resolution;
    resolution = _resolveServicesOnce().whenComplete(() {
      if (identical(_servicesResolution, resolution)) {
        _servicesResolution = null;
      }
    });
    _servicesResolution = resolution;
    return resolution;
  }

  Future<void> _resolveServicesOnce() async {
    final resolver = widget.resolveServices;
    if (resolver == null) {
      return;
    }
    _recordTrace('service-resolve-start');
    final startedAt = _traceClock.nowMicros();
    final services = await resolver();
    _recordTrace(
      'service-resolve-complete',
      payload: <String, Object?>{
        'durationUs': _traceClock.nowMicros() - startedAt,
      },
    );
    if (!mounted) {
      return;
    }
    _adoptServices(services);
    _servicesResolved = true;
  }

  void _adoptServices(DownloadManagerServices services) {
    final downloadsChanged = !identical(_downloads, services.downloads);
    final wholeComicChanged =
        !identical(_wholeComicDownloads, services.wholeComicDownloads);
    final cacheChanged =
        !identical(_cacheCoordinator, services.cacheCoordinator);
    if (!downloadsChanged && !wholeComicChanged && !cacheChanged) {
      return;
    }
    final oldDownloadSubscription = _subscription;
    final oldManagementProjectionSubscription =
        _managementProjectionSubscription;
    final oldWholeComicSubscription = _wholeComicSubscription;
    _downloads = services.downloads;
    _wholeComicDownloads = services.wholeComicDownloads;
    _cacheCoordinator = services.cacheCoordinator;
    if (downloadsChanged) {
      unawaited(oldDownloadSubscription?.cancel());
      unawaited(oldManagementProjectionSubscription?.cancel());
      _subscription = _listenToDownloads(_downloads);
      _managementProjectionSubscription =
          _listenToManagementProjectionChanges(_downloads);
    }
    if (wholeComicChanged) {
      unawaited(oldWholeComicSubscription?.cancel());
      _wholeComicSubscription = _listenToWholeComicDownloads(
        _wholeComicDownloads,
      );
    }
    setState(() {
      if (wholeComicChanged) {
        _wholeComicSnapshot = _wholeComicDownloads.snapshot;
      }
      if (cacheChanged) {
        _cacheUsage = null;
      }
    });
    if (cacheChanged && _selectedTab == DownloadManagerTab.autoCache) {
      unawaited(_refreshCacheUsage());
    }
  }

  StreamSubscription<ChapterDownloadSnapshot> _listenToDownloads(
    ChapterDownloadService downloads,
  ) =>
      downloads.changes.listen((snapshot) {
        if (identical(downloads, _downloads)) {
          _acceptSnapshot(snapshot);
        }
      });

  StreamSubscription<void>? _listenToManagementProjectionChanges(
    ChapterDownloadService downloads,
  ) {
    final source = downloads is ChapterDownloadManagementChangeSource
        ? downloads as ChapterDownloadManagementChangeSource
        : null;
    if (source == null) return null;
    return source.managementProjectionChanges.listen((_) {
      if (mounted && identical(downloads, _downloads)) {
        _scheduleManagementProjectionRefresh();
      }
    });
  }

  void _scheduleManagementProjectionRefresh() {
    _managementProjectionRefreshTimer?.cancel();
    _managementProjectionRefreshTimer = Timer(
      const Duration(milliseconds: 120),
      () => unawaited(_refreshManagementProjection()),
    );
  }

  Future<void> _refreshManagementProjection() {
    final active = _managementProjectionRefresh;
    if (active != null) {
      _managementProjectionRefreshPending = true;
      return active;
    }
    late final Future<void> run;
    run = _refreshManagementProjectionOnce().whenComplete(() {
      if (identical(_managementProjectionRefresh, run)) {
        _managementProjectionRefresh = null;
      }
      if (_managementProjectionRefreshPending && mounted) {
        _managementProjectionRefreshPending = false;
        _scheduleManagementProjectionRefresh();
      }
    });
    _managementProjectionRefresh = run;
    return run;
  }

  Future<void> _refreshManagementProjectionOnce() async {
    if (!mounted) return;
    final startedAt = _traceClock.nowMicros();
    try {
      final refreshProjection = widget.refreshProjection;
      if (refreshProjection != null) {
        await refreshProjection();
        if (!mounted) return;
        _handleProjectionChanged();
      } else {
        final reader = _downloads is ChapterDownloadManagementProjectionReader
            ? _downloads as ChapterDownloadManagementProjectionReader
            : null;
        if (reader == null) return;
        final projection =
            await reader.inspectDownloadManagement(_entries.values);
        if (!mounted) return;
        setState(() {
          for (final entry in projection.orphanedEntries) {
            _rememberEntry(entry);
          }
          _snapshots
            ..clear()
            ..addEntries(
              projection.snapshots.map(
                (snapshot) => MapEntry(snapshot.identity, snapshot),
              ),
            );
          _cacheProjection = projection.cache;
        });
      }
      if (_selectedTab == DownloadManagerTab.autoCache) {
        await _refreshCacheUsage();
      }
      _recordTrace(
        'durable-projection-auto-refresh',
        payload: <String, Object?>{
          'durationUs': _traceClock.nowMicros() - startedAt,
        },
      );
    } on Object catch (error) {
      _recordTrace(
        'durable-projection-auto-refresh-failed',
        payload: <String, Object?>{'error': error.toString()},
      );
    }
  }

  bool get _expectsPhysicalCacheProjection => widget.refreshProjection != null;

  Future<void> _ensureAutoCacheProjection() async {
    if (_cacheProjection != null || !_expectsPhysicalCacheProjection) return;
    try {
      await _resolveServices();
      if (!mounted ||
          _selectedTab != DownloadManagerTab.autoCache ||
          _cacheProjection != null ||
          !_expectsPhysicalCacheProjection) {
        return;
      }
      await _refreshManagementProjection();
    } on Object catch (error) {
      _recordTrace(
        'canonical-cache-projection-hydrate-failed',
        payload: <String, Object?>{'error': error.toString()},
      );
    }
  }

  StreamSubscription<WholeComicQueueSnapshot> _listenToWholeComicDownloads(
    WholeComicDownloadQueue wholeComicDownloads,
  ) =>
      wholeComicDownloads.changes.listen((snapshot) {
        if (mounted && identical(wholeComicDownloads, _wholeComicDownloads)) {
          setState(() => _wholeComicSnapshot = snapshot);
        }
      });

  void _acceptSnapshot(ChapterDownloadSnapshot snapshot) {
    if (!mounted) {
      return;
    }
    final matchingKey = _matchingEntryIdentity(snapshot);
    setState(() {
      _snapshots[matchingKey] = snapshot;
      if (matchingKey != snapshot.identity) {
        _snapshots[snapshot.identity] = snapshot;
      }
    });
  }

  void _handleProjectionChanged() {
    final readProjection = widget.readProjection;
    if (!mounted || readProjection == null) {
      return;
    }
    final startedAt = _traceClock.nowMicros();
    final projection = readProjection();
    _adoptProjection(projection);
    _recordTrace(
      'projection-changed',
      payload: <String, Object?>{
        'entries': projection.entries.length,
        'snapshots': projection.snapshots.length,
        'durationUs': _traceClock.nowMicros() - startedAt,
      },
    );
  }

  void _adoptProjection(DownloadManagerProjection projection) {
    setState(() {
      _replaceEntries(projection.entries);
      _versionBaselines =
          _DownloadVersionBaselineIndex(projection.versionBaselines);
      _snapshots
        ..clear()
        ..addEntries(
          projection.snapshots.map(
            (snapshot) => MapEntry(snapshot.identity, snapshot),
          ),
        );
      _cacheProjection = projection.cacheProjection;
      _wholeComicSnapshot = projection.wholeComicSnapshot;
    });
  }

  Future<void> _refreshAfterFirstFrame() async {
    _recordTrace('post-frame-refresh-start');
    if (widget.readProjection == null) {
      await _reload();
      _recordTrace('post-frame-refresh-complete');
      return;
    }
    try {
      await _resolveServices();
      if (!mounted) {
        return;
      }
      _handleProjectionChanged();
      _refreshWholeComicSnapshotWhenReady();
      _recordTrace('post-frame-refresh-complete');
    } on Object catch (error) {
      if (mounted) {
        _showError(error);
      }
    }
  }

  void _refreshWholeComicSnapshotWhenReady() {
    final queue = _wholeComicDownloads;
    unawaited(
      queue.ready.then<void>(
        (_) {
          if (mounted && identical(queue, _wholeComicDownloads)) {
            setState(() => _wholeComicSnapshot = queue.snapshot);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (mounted && identical(queue, _wholeComicDownloads)) {
            _showError(error);
          }
        },
      ),
    );
  }

  Future<void> _reload() async {
    if (mounted) {
      setState(() => _loading = true);
    }
    try {
      await _resolveServices();
      if (!mounted) {
        return;
      }
      final queue = _wholeComicDownloads;
      final inspectCache = _selectedTab == DownloadManagerTab.autoCache;
      final cacheRefresh = inspectCache
          ? _refreshCacheUsage()
          : Future<void>.value();
      List<ChapterDownloadSnapshot>? snapshots;
      final refreshProjection = widget.refreshProjection;
      if (refreshProjection != null) {
        await refreshProjection();
        if (!mounted) {
          return;
        }
        _handleProjectionChanged();
      } else {
        final loadedEntries = await widget.loadAllEntries?.call();
        if (loadedEntries != null) {
          for (final entry in loadedEntries) {
            _rememberEntry(entry);
          }
        }
        final projectionReader =
            _downloads is ChapterDownloadManagementProjectionReader
                ? _downloads as ChapterDownloadManagementProjectionReader
                : null;
        if (projectionReader != null) {
          final projection =
              await projectionReader.inspectDownloadManagement(_entries.values);
          for (final entry in projection.orphanedEntries) {
            _rememberEntry(entry);
          }
          snapshots = projection.snapshots;
        } else {
          final orphaned =
              await _downloads.discoverOrphanedEntries(_entries.values);
          for (final entry in orphaned) {
            _rememberEntry(entry);
          }
          snapshots = await _downloads.inspectMany(_entries.values);
        }
      }
      await cacheRefresh;
      await queue.ready;
      if (!mounted || !identical(queue, _wholeComicDownloads)) {
        return;
      }
      setState(() {
        if (snapshots != null) {
          // Rebuild, never upsert: superseded-revision snapshots surviving
          // here feed the dedup stale progress.
          _snapshots
            ..clear()
            ..addEntries(
              snapshots.map(
                (snapshot) => MapEntry(snapshot.identity, snapshot),
              ),
            );
        }
        _wholeComicSnapshot = queue.snapshot;
      });
    } on Object catch (error) {
      if (mounted) {
        _showError(error);
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _refreshCacheUsage() {
    final coordinator = _cacheCoordinator;
    if (coordinator == null) {
      return Future<void>.value();
    }
    final existing = _cacheUsageRefresh;
    if (existing != null &&
        identical(coordinator, _cacheUsageRefreshCoordinator)) {
      return existing;
    }
    late final Future<void> refresh;
    refresh = _refreshCacheUsageOnce(coordinator).whenComplete(() {
      if (identical(_cacheUsageRefresh, refresh)) {
        _cacheUsageRefresh = null;
        _cacheUsageRefreshCoordinator = null;
      }
    });
    _cacheUsageRefreshCoordinator = coordinator;
    _cacheUsageRefresh = refresh;
    return refresh;
  }

  Future<void> _refreshCacheUsageOnce(
    ResourceCacheCoordinator coordinator,
  ) async {
    try {
      final usage = await coordinator.inspect();
      if (mounted && identical(coordinator, _cacheCoordinator)) {
        setState(() => _cacheUsage = usage);
      }
    } on Object catch (error) {
      if (mounted) {
        _showError(error);
      }
    }
  }

  List<ChapterDownloadSnapshot> get _manualSnapshots {
    final deduped = <String, ChapterDownloadSnapshot>{};
    for (final snapshot in _snapshots.values) {
      if (!snapshot.isManualDownload ||
          (snapshot.phase == ChapterDownloadPhase.idle &&
              !snapshot.hasDurableBytes)) {
        continue;
      }
      final key = _versionBaselines.chapterBaselineKey(
        snapshot.sourceId,
        snapshot.comicId,
        snapshot.chapterId,
      );
      final existing = deduped[key];
      deduped[key] = existing == null
          ? snapshot
          : _preferManualFamilySnapshot(existing, snapshot);
    }
    final values = deduped.values.toList(growable: false);
    _sortSnapshots(values);
    return values;
  }

  void _sortSnapshots(List<ChapterDownloadSnapshot> values) {
    values.sort((left, right) {
      final phase = _phasePriority(left.phase).compareTo(
        _phasePriority(right.phase),
      );
      if (phase != 0) return phase;
      final comic = left.comicId.compareTo(right.comicId);
      if (comic != 0) return comic;
      return left.title.compareTo(right.title);
    });
  }

  List<ChapterDownloadSnapshot> get _autoCacheSnapshots {
    final manualIdentities = {
      for (final snapshot in _manualSnapshots) snapshot.identity,
    };
    final cacheAll = _snapshots.values.where(
      (snapshot) =>
          !snapshot.isManualDownload &&
          (snapshot.hasAutoCache || !_isLibraryEntry(snapshot)) &&
          (snapshot.phase != ChapterDownloadPhase.idle ||
              snapshot.hasDurableBytes),
    );
    final deduped = <String, ChapterDownloadSnapshot>{};
    for (final snapshot in cacheAll) {
      final key =
          '${snapshot.sourceId}\u0000${snapshot.comicId}\u0000${snapshot.chapterId}';
      final existing = deduped[key];
      deduped[key] =
          existing == null ? snapshot : _preferRowSnapshot(existing, snapshot);
    }
    final values = deduped.values
        .where((snapshot) => !manualIdentities.contains(snapshot.identity))
        .toList(growable: false);
    _sortSnapshots(values);
    return values;
  }

  bool _isLibraryEntry(ChapterDownloadSnapshot snapshot) {
    final entry = _entryFor(snapshot);
    return entry != null && !entry.chapter.directoryId.startsWith('orphaned:');
  }

  ImportedLibraryEntry? _entryFor(ChapterDownloadSnapshot snapshot) {
    final exact = _entries[snapshot.identity];
    if (exact != null) {
      return exact;
    }
    final identity = _entryIdentityByChapter[
      _chapterIdentity(
        snapshot.sourceId,
        snapshot.comicId,
        snapshot.chapterId,
      )
    ];
    return identity == null ? null : _entries[identity];
  }

  /// Row display when several revisions of one chapter coexist: library-bound
  /// entries win first over orphans, then entry-bound snapshot wins over stale,
  /// then manual download status, then activity/completion, then page count.
  ChapterDownloadSnapshot _preferRowSnapshot(
    ChapterDownloadSnapshot current,
    ChapterDownloadSnapshot candidate,
  ) {
    final candidateIsLibrary = _isLibraryEntry(candidate);
    final currentIsLibrary = _isLibraryEntry(current);
    if (candidateIsLibrary != currentIsLibrary) {
      return candidateIsLibrary ? candidate : current;
    }
    final candidateBound = _entries.containsKey(candidate.identity);
    final currentBound = _entries.containsKey(current.identity);
    if (candidateBound != currentBound) {
      return candidateBound ? candidate : current;
    }
    if (candidate.isManualDownload != current.isManualDownload) {
      return candidate.isManualDownload ? candidate : current;
    }
    if (candidate.isActive != current.isActive) {
      return candidate.isActive ? candidate : current;
    }
    if (candidate.isComplete != current.isComplete) {
      return candidate.isComplete ? candidate : current;
    }
    return candidate.completedPages > current.completedPages
        ? candidate
        : current;
  }

  ChapterDownloadSnapshot _preferManualFamilySnapshot(
    ChapterDownloadSnapshot current,
    ChapterDownloadSnapshot candidate,
  ) {
    final candidateIsHead = _versionBaselines.isDownloadHead(candidate);
    final currentIsHead = _versionBaselines.isDownloadHead(current);
    if (candidateIsHead != currentIsHead) {
      return candidateIsHead ? candidate : current;
    }
    return _preferRowSnapshot(current, candidate);
  }

  ChapterDownloadSnapshot? _preferredCanonicalDownloadSnapshot(
    CanonicalChapterCacheSnapshot cache,
  ) {
    final candidates = <ChapterDownloadSnapshot>[
      for (final identity in cache.memberChapterIdentities)
        if (_snapshots[identity] case final snapshot? when _entryFor(snapshot) != null)
          snapshot,
    ];
    if (candidates.isEmpty) return null;

    final first = candidates.first;
    final preferredComicId = _versionBaselines.preferredCanonicalComicId(
      first.sourceId,
      first.comicId,
    );
    if (preferredComicId != null) {
      ChapterDownloadSnapshot? selected;
      for (final candidate in candidates) {
        if (candidate.comicId != preferredComicId) continue;
        selected = selected == null
            ? candidate
            : _preferRowSnapshot(selected, candidate);
      }
      // The family has an authoritative target, but its exact chapter is not
      // currently materialized in this management projection. Do not guess an
      // older version merely because it happens to own resident bytes.
      return selected;
    }

    final comicIds = <String>{for (final candidate in candidates) candidate.comicId};
    if (comicIds.length != 1) return null;
    var selected = candidates.first;
    for (final candidate in candidates.skip(1)) {
      selected = _preferRowSnapshot(selected, candidate);
    }
    return selected;
  }

  Future<void> _convertCanonicalCacheToDownload(
    CanonicalChapterCacheSnapshot cache,
  ) async {
    final target = _preferredCanonicalDownloadSnapshot(cache);
    if (target == null) {
      _showError(StateError('Canonical 缓存没有可用的当前版本章节'));
      return;
    }
    await _act(target, _downloads.download, actionKey: 'convert');
    if (mounted) {
      setState(() => _selectedTab = DownloadManagerTab.manual);
    }
  }

  Future<void> _act(
    ChapterDownloadSnapshot snapshot,
    Future<void> Function(ImportedLibraryEntry entry) action, {
    required String actionKey,
  }) async {
    final lockKey = '${snapshot.identity}:$actionKey';
    final blocked = _busyActionKeys.contains(lockKey);
    try {
      widget.traceSink.record(
        traceEvent(
          clock: _traceClock,
          sessionId: 'download-manager',
          kind: TraceEventKind.downloadState,
          identityHash: snapshot.identity,
          payload: <String, Object?>{
            'stage': 'manager-action',
            'action': actionKey,
            'phase': snapshot.phase.name,
            'started': snapshot.started,
            'blocked': blocked,
          },
        ),
      );
    } on Object {
      // Diagnostics must never change action behavior.
    }
    if (blocked) {
      return;
    }
    setState(() {
      _busyActionKeys.add(lockKey);
    });
    try {
      await _performTaskAction(snapshot, action);
    } finally {
      if (mounted) {
        setState(() {
          _busyActionKeys.remove(lockKey);
        });
      } else {
        _busyActionKeys.remove(lockKey);
      }
    }
  }

  Future<void> _performTaskAction(
    ChapterDownloadSnapshot snapshot,
    Future<void> Function(ImportedLibraryEntry entry) action,
  ) async {
    final initialEntry = _entryFor(snapshot);
    if (initialEntry == null) {
      _showError(StateError('下载任务对应的章节记录已不存在'));
      return;
    }
    var entry = initialEntry;
    if (widget.hydrateEntry != null) {
      try {
        final hydrated = await widget.hydrateEntry!(initialEntry);
        entry = hydrated;
        _rememberEntry(hydrated);
      } on Object {
        // Fall back to the projection entry when hydration is unavailable.
      }
    }
    try {
      await action(entry);
      final next = await _downloads.inspect(entry);
      _acceptSnapshot(next);
    } on Object catch (error) {
      if (mounted) {
        _showError(error);
      }
    }
  }

  Future<void> _convertCacheToDownload(ChapterDownloadSnapshot snapshot) async {
    await _act(snapshot, _downloads.download, actionKey: 'convert');
    if (mounted) {
      setState(() {
        _selectedTab = DownloadManagerTab.manual;
      });
    }
  }

  Future<void> _delete(ChapterDownloadSnapshot snapshot) async {
    final lockKey = '${snapshot.identity}:delete';
    if (_busyActionKeys.contains(lockKey)) {
      return;
    }
    if (_entryFor(snapshot) == null) {
      _showError(StateError('下载任务对应的章节记录已不存在'));
      return;
    }
    setState(() {
      _busyActionKeys.add(lockKey);
    });
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除离线章节？'),
          content: Text('将删除“${snapshot.title}”的离线页面，阅读记录不会被删除。'),
          actions: <Widget>[
            AppDialogActions(
              onClose: () => Navigator.pop(context, false),
              actions: <Widget>[
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('删除'),
                ),
              ],
            ),
          ],
        ),
      );
      if (confirmed == true && mounted) {
        await _performTaskAction(snapshot, _downloads.delete);
      }
    } finally {
      if (mounted) {
        setState(() {
          _busyActionKeys.remove(lockKey);
        });
      } else {
        _busyActionKeys.remove(lockKey);
      }
    }
  }

  void _showError(Object error) {
    final details = error.toString();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(details, maxLines: 3),
        action: SnackBarAction(
          label: '复制',
          onPressed: () => unawaited(
            Clipboard.setData(ClipboardData(text: details)),
          ),
        ),
      ),
    );
  }

  Future<void> _trimCache() async {
    final maintenance = _cacheCoordinator;
    if (maintenance == null || _cacheBusy) {
      return;
    }
    setState(() => _cacheBusy = true);
    try {
      final report = await maintenance.trim();
      if (!mounted) {
        return;
      }
      final artifactReport = report.artifacts;
      final message = artifactReport == null
          ? '临时响应缓存整理完成：释放 ${_formatBytes(report.totalReleasedBytes)}'
          : '缓存整理完成：释放 ${_formatBytes(report.totalReleasedBytes)}，'
              'artifact 剩余 ${_formatBytes(artifactReport.remainingBytes)}';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
      await _reload();
    } on Object catch (error) {
      if (mounted) {
        _showError(error);
      }
    } finally {
      if (mounted) {
        setState(() => _cacheBusy = false);
      }
    }
  }

  Future<void> _clearCache() async {
    final maintenance = _cacheCoordinator;
    if (maintenance == null || _cacheBusy) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除离线缓存？'),
        content: const Text(
          '将删除当前未被下载任务占用的离线页面。漫画、章节、阅读进度和已读状态不会删除。',
        ),
        actions: <Widget>[
          AppDialogActions(
            onClose: () => Navigator.pop(context, false),
            actions: <Widget>[
              FilledButton(
                key: downloadCacheClearKey,
                onPressed: () => Navigator.pop(context, true),
                child: const Text('清除缓存'),
              ),
            ],
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() => _cacheBusy = true);
    try {
      final report = await maintenance.clear();
      if (!mounted) {
        return;
      }
      final artifactReport = report.artifacts;
      final message = artifactReport == null
          ? '网络响应缓存已清空，释放 ${_formatBytes(report.totalReleasedBytes)}'
          : '已释放 ${_formatBytes(report.totalReleasedBytes)}，'
              '${artifactReport.skippedBusy} 个活动 artifact 被保留';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
      await _reload();
    } on Object catch (error) {
      if (mounted) {
        _showError(error);
      }
    } finally {
      if (mounted) {
        setState(() => _cacheBusy = false);
      }
    }
  }

  Future<void> _editQueuePolicy() async {
    var next = _wholeComicSnapshot.policy;
    final selected = await showDialog<WholeComicQueuePolicy>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('整本下载队列策略'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('并发章节数'),
                const SizedBox(height: 8),
                SegmentedButton<int>(
                  segments: const <ButtonSegment<int>>[
                    ButtonSegment(value: 1, label: Text('1')),
                    ButtonSegment(value: 2, label: Text('2')),
                    ButtonSegment(value: 3, label: Text('3')),
                    ButtonSegment(value: 4, label: Text('4')),
                  ],
                  selected: <int>{next.concurrency},
                  onSelectionChanged: (value) => setDialogState(() {
                    next = next.copyWith(concurrency: value.single);
                  }),
                ),
                const SizedBox(height: 20),
                DropdownButtonFormField<WholeComicNetworkPolicy>(
                  value: next.network,
                  decoration: const InputDecoration(labelText: '网络策略'),
                  items: const <DropdownMenuItem<WholeComicNetworkPolicy>>[
                    DropdownMenuItem(
                      value: WholeComicNetworkPolicy.any,
                      child: Text('任意可用网络'),
                    ),
                    DropdownMenuItem(
                      value: WholeComicNetworkPolicy.unmetered,
                      child: Text('仅非计费网络'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(
                          () => next = next.copyWith(network: value));
                    }
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<WholeComicPowerPolicy>(
                  value: next.power,
                  decoration: const InputDecoration(labelText: '供电策略'),
                  items: const <DropdownMenuItem<WholeComicPowerPolicy>>[
                    DropdownMenuItem(
                      value: WholeComicPowerPolicy.any,
                      child: Text('任意供电状态'),
                    ),
                    DropdownMenuItem(
                      value: WholeComicPowerPolicy.charging,
                      child: Text('仅充电时'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => next = next.copyWith(power: value));
                    }
                  },
                ),
                const SizedBox(height: 12),
                Text(
                  'Android 会使用系统网络计费和充电状态；其他平台或桥不可用时使用应用注入的环境。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          actions: <Widget>[
            AppDialogActions(
              onClose: () => Navigator.pop(context),
              actions: <Widget>[
                FilledButton(
                  onPressed: () => Navigator.pop(context, next),
                  child: const Text('保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) {
      return;
    }
    try {
      await _wholeComicDownloads.updatePolicy(selected);
    } on Object catch (error) {
      if (mounted) {
        _showError(error);
      }
    }
  }

  Future<void> _queueAction(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error) {
      if (mounted) {
        _showError(error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: downloadManagerScreenKey,
      appBar: AppBar(
        title: const Text('下载管理'),
        actions: <Widget>[
          if (_selectedTab == DownloadManagerTab.manual)
            IconButton(
              key: downloadQueuePolicyKey,
              tooltip: '整本下载队列策略',
              onPressed: () => unawaited(_editQueuePolicy()),
              icon: const Icon(Icons.tune),
            ),
          IconButton(
            key: downloadManagerRefreshKey,
            tooltip: '刷新下载状态',
            onPressed: _loading ? null : _reload,
            icon: _loading
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: _selectedTab == DownloadManagerTab.manual
            ? _buildManualTab(context)
            : _buildAutoCacheTab(context),
      ),
      bottomNavigationBar: NavigationBar(
        key: downloadManagerBottomNavKey,
        selectedIndex: _selectedTab.index,
        onDestinationSelected: (index) {
          final selected = DownloadManagerTab.values[index];
          setState(() => _selectedTab = selected);
          if (selected == DownloadManagerTab.autoCache) {
            if (_cacheUsage == null) {
              unawaited(_refreshCacheUsage());
            }
            if (_cacheProjection == null) {
              unawaited(_ensureAutoCacheProjection());
            }
          }
        },
        destinations: const <NavigationDestination>[
          NavigationDestination(
            key: downloadManagerTabManualKey,
            icon: Icon(Icons.download_outlined),
            selectedIcon: Icon(Icons.download),
            label: '手动下载任务',
          ),
          NavigationDestination(
            key: downloadManagerTabCacheKey,
            icon: Icon(Icons.cached_outlined),
            selectedIcon: Icon(Icons.cached),
            label: 'Canonical 缓存',
          ),
        ],
      ),
    );
  }

  Widget _buildManualTab(BuildContext context) {
    final manualSnapshots = _manualSnapshots;
    final wholeJobs = _wholeComicSnapshot.jobs;
    if (manualSnapshots.isEmpty && wholeJobs.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const <Widget>[
          SizedBox(height: 160),
          Icon(Icons.download_done_outlined, size: 48),
          SizedBox(height: 12),
          Center(child: Text('暂无手动下载任务')),
        ],
      );
    }
    final itemCount = (wholeJobs.isNotEmpty ? 2 + wholeJobs.length : 0) +
        (manualSnapshots.isNotEmpty ? 1 + manualSnapshots.length * 2 - 1 : 0);
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (wholeJobs.isNotEmpty) {
          if (index == 0) {
            return const _DownloadSectionHeader(title: '整本下载队列');
          }
          if (index <= wholeJobs.length) {
            final job = wholeJobs[index - 1];
            return _WholeComicQueueTile(
              key: wholeComicQueueJobKey(job.jobId),
              job: job,
              onPause: () => _queueAction(
                () => _wholeComicDownloads.pause(job.jobId),
              ),
              onResume: () => _queueAction(
                () => _wholeComicDownloads.resume(job.jobId),
              ),
              onCancel: () => _queueAction(
                () => _wholeComicDownloads.cancel(job.jobId),
              ),
              onRetry: () => _queueAction(
                () => _wholeComicDownloads.retry(job.jobId),
              ),
              onRemove: () => _queueAction(
                () => _wholeComicDownloads.remove(job.jobId),
              ),
            );
          }
          if (index == wholeJobs.length + 1) {
            return const Divider(height: 24);
          }
        }
        final manualIndex = index - (wholeJobs.isNotEmpty ? wholeJobs.length + 2 : 0);
        if (manualIndex == 0) {
          return const _DownloadSectionHeader(title: '下载任务与离线章节');
        }
        final snapshotIndex = (manualIndex - 1) ~/ 2;
        if ((manualIndex - 1).isOdd) {
          return const Divider(height: 1);
        }
        final snapshot = manualSnapshots[snapshotIndex];
        return _DownloadTaskTile(
          key: downloadManagerTaskKey(snapshot.identity),
          snapshot: snapshot,
          isCancellingOrRetrying: _isActionBusy(snapshot.identity, 'stop') ||
              _isActionBusy(snapshot.identity, 'retry'),
          isDeleting: _isActionBusy(snapshot.identity, 'delete'),
          onCancel: () => _act(snapshot, _downloads.cancel, actionKey: 'stop'),
          onRetry: () => _act(snapshot, _downloads.retry, actionKey: 'retry'),
          onDelete: () => _delete(snapshot),
        );
      },
    );
  }

  Widget _buildAutoCacheTab(BuildContext context) {
    final projection = _cacheProjection;
    if (projection != null) {
      return _buildProjectedCacheTab(context, projection);
    }
    if (_expectsPhysicalCacheProjection) {
      final children = <Widget>[];
      if (_cacheCoordinator != null) {
        children.add(
          _DownloadCacheSummary(
            usage: _cacheUsage,
            busy: _cacheBusy,
            onTrim: _trimCache,
            onClear: _clearCache,
          ),
        );
        children.add(const Divider(height: 24));
      }
      children.addAll(const <Widget>[
        SizedBox(height: 72),
        Center(child: CircularProgressIndicator()),
        SizedBox(height: 16),
        Center(child: Text('正在读取 Canonical 缓存…')),
        SizedBox(height: 72),
      ]);
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: children,
      );
    }

    // Compatibility path for in-memory/test services that do not expose the
    // physical cache-management projection yet.
    final autoCacheSnapshots = _autoCacheSnapshots;
    final hasSummary = _cacheCoordinator != null;
    final hasItems = autoCacheSnapshots.isNotEmpty;
    final itemCount = (hasSummary ? 2 : 0) +
        (hasItems ? autoCacheSnapshots.length * 2 : 5);
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (hasSummary) {
          if (index == 0) {
            return _DownloadCacheSummary(
              usage: _cacheUsage,
              busy: _cacheBusy,
              onTrim: _trimCache,
              onClear: _clearCache,
            );
          }
          if (index == 1) return const Divider(height: 24);
        }
        final contentIndex = index - (hasSummary ? 2 : 0);
        if (!hasItems) {
          return switch (contentIndex) {
            0 => const SizedBox(height: 72),
            1 => const Icon(Icons.cached_outlined, size: 48),
            2 => const SizedBox(height: 12),
            3 => const Center(child: Text('暂无页面自动缓存')),
            _ => const SizedBox(height: 72),
          };
        }
        if (contentIndex == 0) {
          return const _DownloadSectionHeader(title: '页面缓存章节');
        }
        final itemIndex = (contentIndex - 1) ~/ 2;
        if ((contentIndex - 1).isOdd) return const Divider(height: 1);
        final snapshot = autoCacheSnapshots[itemIndex];
        return _AutoCacheTaskTile(
          key: downloadManagerAutoCacheTaskKey(snapshot.identity),
          snapshot: snapshot,
          isDeleting: _isActionBusy(snapshot.identity, 'delete'),
          isConverting: _isActionBusy(snapshot.identity, 'convert'),
          onDelete: () => _delete(snapshot),
          onConvert: () => _convertCacheToDownload(snapshot),
        );
      },
    );
  }

  Widget _buildProjectedCacheTab(
    BuildContext context,
    ChapterCacheManagementProjection projection,
  ) {
    final children = <Widget>[];
    if (_cacheCoordinator != null) {
      children.add(
        _DownloadCacheSummary(
          usage: _cacheUsage,
          busy: _cacheBusy,
          onTrim: _trimCache,
          onClear: _clearCache,
        ),
      );
      children.add(const Divider(height: 24));
    }

    if (projection.canonical.isNotEmpty) {
      children.add(
        const _DownloadSectionHeader(title: 'Canonical 页面缓存'),
      );
      for (var index = 0; index < projection.canonical.length; index++) {
        if (index > 0) children.add(const Divider(height: 1));
        final cache = projection.canonical[index];
        final target = _preferredCanonicalDownloadSnapshot(cache);
        final canConvert = target != null && !target.isManualDownload;
        children.add(
          _CanonicalCacheTaskTile(
            key: downloadManagerCanonicalCacheTaskKey(cache.identity),
            cache: cache,
            target: target,
            isConverting: target != null &&
                _isActionBusy(target.identity, 'convert'),
            onConvert: canConvert
                ? () => _convertCanonicalCacheToDownload(cache)
                : null,
          ),
        );
      }
    }

    if (projection.exact.isNotEmpty) {
      if (projection.canonical.isNotEmpty) {
        children.add(const Divider(height: 24));
      }
      children.add(
        const _DownloadSectionHeader(title: '未归入 Canonical 的页面缓存'),
      );
      for (var index = 0; index < projection.exact.length; index++) {
        if (index > 0) children.add(const Divider(height: 1));
        final cache = projection.exact[index];
        final snapshot = _snapshots[cache.identity];
        final canMutate = snapshot != null &&
            !snapshot.isManualDownload &&
            _entryFor(snapshot) != null;
        children.add(
          _ExactCacheTaskTile(
            key: downloadManagerAutoCacheTaskKey(cache.identity),
            cache: cache,
            isDeleting: canMutate &&
                _isActionBusy(cache.identity, 'delete'),
            isConverting: canMutate &&
                _isActionBusy(cache.identity, 'convert'),
            onDelete: canMutate ? () => _delete(snapshot) : null,
            onConvert: canMutate
                ? () => _convertCacheToDownload(snapshot)
                : null,
          ),
        );
      }
    }

    if (projection.canonical.isEmpty && projection.exact.isEmpty) {
      children.addAll(const <Widget>[
        SizedBox(height: 72),
        Icon(Icons.cached_outlined, size: 48),
        SizedBox(height: 12),
        Center(child: Text('暂无页面缓存')),
        SizedBox(height: 72),
      ]);
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: children,
    );
  }

}

final class _DownloadCacheSummary extends StatelessWidget {
  const _DownloadCacheSummary({
    required this.usage,
    required this.busy,
    required this.onTrim,
    required this.onClear,
  });

  final ResourceCacheUsage? usage;
  final bool busy;
  final VoidCallback onTrim;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final current = usage;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('资源缓存', style: Theme.of(context).textTheme.titleMedium),
                Text(
                  current == null
                      ? '正在统计缓存…'
                      : '${_formatBytes(current.totalBytes)} · ${current.totalEntries} 个缓存记录',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  current == null
                      ? '统一统计资源响应内存、持久响应与页面 artifact。'
                      : '内存 ${_formatBytes(current.responses.weight)} · '
                          '持久响应 ${_formatBytes(current.persistentResponses?.bytes ?? 0)} '
                          '（保留 ${_formatBytes(current.persistentResponses?.retainedBytes ?? 0)} / '
                          '临时 ${_formatBytes(current.persistentResponses?.transientBytes ?? 0)}） · '
                          'artifact ${_formatBytes(current.artifacts?.bytes ?? 0)}；'
                          '活动需求与写入不会被清理。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (current != null)
                  Text(
                    _memoryKindSummary(current.responses),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else ...<Widget>[
            IconButton(
              key: downloadCacheTrimKey,
              tooltip: '整理可回收缓存',
              onPressed: onTrim,
              icon: const Icon(Icons.auto_delete_outlined),
            ),
            IconButton(
              tooltip: '清除可回收缓存',
              onPressed: onClear,
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
          ],
        ],
      ),
    );
  }
}

final class _DownloadSectionHeader extends StatelessWidget {
  const _DownloadSectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );
}

final class _WholeComicQueueTile extends StatelessWidget {
  const _WholeComicQueueTile({
    required this.job,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
    required this.onRetry,
    required this.onRemove,
    super.key,
  });

  final WholeComicQueueJobSnapshot job;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onCancel;
  final VoidCallback onRetry;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final active = job.activeChapterTitles;
    final failure = job.failure;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      job.comicTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      '${job.sourceId} · ${_wholeQueuePhaseLabel(job.phase)}'
                      ' · ${job.completedChapters}/${job.totalChapters} 章',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (active.isNotEmpty)
                      Text(
                        '正在下载：${active.join('、')}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              if (job.canPause)
                IconButton(
                  key: wholeComicQueuePauseKey(job.jobId),
                  tooltip: '暂停整本下载',
                  onPressed: onPause,
                  icon: const Icon(Icons.pause_circle_outline),
                )
              else if (job.canResume)
                IconButton(
                  key: wholeComicQueueResumeKey(job.jobId),
                  tooltip: '继续整本下载',
                  onPressed: onResume,
                  icon: const Icon(Icons.play_circle_outline),
                )
              else if (job.canRetry)
                IconButton(
                  key: wholeComicQueueRetryKey(job.jobId),
                  tooltip: '重试整本下载',
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                ),
              if (job.phase != WholeComicQueuePhase.complete &&
                  job.phase != WholeComicQueuePhase.cancelled)
                IconButton(
                  key: wholeComicQueueCancelKey(job.jobId),
                  tooltip: '取消整本下载',
                  onPressed: onCancel,
                  icon: const Icon(Icons.stop_circle_outlined),
                ),
              IconButton(
                key: wholeComicQueueRemoveKey(job.jobId),
                tooltip: '移除队列记录',
                onPressed: onRemove,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          if (job.phase != WholeComicQueuePhase.complete) ...<Widget>[
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: job.phase == WholeComicQueuePhase.running &&
                      job.completedPageUnits == 0
                  ? null
                  : job.fraction,
            ),
            const SizedBox(height: 6),
            Text(
              '${job.completedPages}/${job.totalPages} 页',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (failure != null && failure.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            SelectableText(
              failure,
              maxLines: 3,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}

final class _DownloadTaskTile extends StatelessWidget {
  const _DownloadTaskTile({
    required this.snapshot,
    this.isCancellingOrRetrying = false,
    this.isDeleting = false,
    required this.onCancel,
    required this.onRetry,
    required this.onDelete,
    super.key,
  });

  final ChapterDownloadSnapshot snapshot;
  final bool isCancellingOrRetrying;
  final bool isDeleting;
  final VoidCallback onCancel;
  final VoidCallback onRetry;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final failure = snapshot.failure;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      snapshot.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      '${snapshot.comicTitle} · ${snapshot.sourceId}'
                      ' · ${_phaseLabel(snapshot.phase)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (snapshot.phase == ChapterDownloadPhase.downloading &&
                  !snapshot.started)
                IconButton(
                  key: downloadManagerCancelKey(snapshot.identity),
                  tooltip: '取消下载',
                  onPressed: onCancel,
                  icon: Stack(
                    alignment: Alignment.center,
                    children: <Widget>[
                      const SizedBox.square(
                        dimension: 30,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                      const Icon(Icons.stop, size: 14),
                    ],
                  ),
                )
              else if (snapshot.phase == ChapterDownloadPhase.downloading)
                IconButton(
                  key: downloadManagerCancelKey(snapshot.identity),
                  tooltip: '停止下载',
                  onPressed: onCancel,
                  icon: const Icon(Icons.stop_circle_outlined),
                )
              else if (isCancellingOrRetrying)
                IconButton(
                  key: downloadManagerCancelKey(snapshot.identity),
                  tooltip: '处理中…',
                  onPressed: null,
                  icon: Stack(
                    alignment: Alignment.center,
                    children: <Widget>[
                      const SizedBox.square(
                        dimension: 30,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                      const Icon(Icons.stop, size: 14),
                    ],
                  ),
                )
              else if (snapshot.phase == ChapterDownloadPhase.failed ||
                  snapshot.phase == ChapterDownloadPhase.cancelled ||
                  // Interrupted chapters lose their in-memory terminal phase
                  // on restart and surface as idle with partial durable
                  // bytes; they must stay resumable from this list.
                  (snapshot.phase == ChapterDownloadPhase.idle &&
                      snapshot.hasDurableBytes))
                IconButton(
                  key: downloadManagerRetryKey(snapshot.identity),
                  tooltip: '重试下载',
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                ),
              const SizedBox(width: 12),
              if (isDeleting)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                IconButton(
                  key: downloadManagerDeleteKey(snapshot.identity),
                  tooltip: '删除离线章节',
                  color: Theme.of(context).colorScheme.error,
                  onPressed: isCancellingOrRetrying ? null : onDelete,
                  icon: const Icon(Icons.delete_outline),
                ),
            ],
          ),
          if (snapshot.phase != ChapterDownloadPhase.complete) ...<Widget>[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: snapshot.phase == ChapterDownloadPhase.downloading &&
                      snapshot.receivedBytes == 0 &&
                      snapshot.completedPages == 0
                  ? null
                  : snapshot.fraction,
            ),
            const SizedBox(height: 6),
          ] else
            const SizedBox(height: 4),
          Text(
            snapshot.pinnedPages > 0 && snapshot.autoCachedPages > 0
                ? '${snapshot.pinnedPages} 页已固定下载 · ${snapshot.autoCachedPages} 页自动缓存（共 ${snapshot.completedPages}/${snapshot.totalPages} 页）'
                    ' · ${_formatBytes(snapshot.receivedBytes)}'
                    '${snapshot.totalBytes == null ? '' : ' / ${_formatBytes(snapshot.totalBytes!)}'}'
                : '${snapshot.completedPages}/${snapshot.totalPages} 页'
                    ' · ${_formatBytes(snapshot.receivedBytes)}'
                    '${snapshot.totalBytes == null ? '' : ' / ${_formatBytes(snapshot.totalBytes!)}'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (failure != null && failure.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: SelectableText(
                    failure,
                    maxLines: 3,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                IconButton(
                  key: downloadManagerCopyErrorKey(snapshot.identity),
                  tooltip: '复制下载错误',
                  onPressed: () => unawaited(
                    Clipboard.setData(ClipboardData(text: failure)),
                  ),
                  icon: const Icon(Icons.copy_outlined),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

final class _CanonicalCacheTaskTile extends StatelessWidget {
  const _CanonicalCacheTaskTile({
    required this.cache,
    required this.target,
    required this.isConverting,
    this.onConvert,
    super.key,
  });

  final CanonicalChapterCacheSnapshot cache;
  final ChapterDownloadSnapshot? target;
  final bool isConverting;
  final VoidCallback? onConvert;

  @override
  Widget build(BuildContext context) {
    final target = this.target;
    final title = target?.title ?? 'Canonical 章节缓存';
    final comicTitle = target?.comicTitle ?? '版本共享缓存';
    final sourceId = target?.sourceId ?? cache.familyId.value;
    final states = <String>[
      if (cache.readyPages > 0) '${cache.readyPages} 页完整',
      if (cache.partialPages > 0) '${cache.partialPages} 页 partial',
      '${cache.memberVersionCount} 个版本共享',
      if (cache.manualReferencedPages > 0)
        '${cache.manualReferencedPages} 页被下载引用',
      _formatBytes(cache.receivedBytes),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(
                  '$comicTitle · $sourceId · Canonical 缓存',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                Text(
                  states.join(' · '),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (isConverting)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (onConvert != null)
            IconButton(
              key: downloadManagerConvertKey(cache.identity),
              tooltip: '转当前版本为下载任务',
              color: Theme.of(context).colorScheme.primary,
              onPressed: onConvert,
              icon: const Icon(Icons.download_outlined),
            ),
        ],
      ),
    );
  }
}

final class _ExactCacheTaskTile extends StatelessWidget {
  const _ExactCacheTaskTile({
    required this.cache,
    required this.isDeleting,
    required this.isConverting,
    this.onDelete,
    this.onConvert,
    super.key,
  });

  final ExactChapterCacheSnapshot cache;
  final bool isDeleting;
  final bool isConverting;
  final VoidCallback? onDelete;
  final VoidCallback? onConvert;

  @override
  Widget build(BuildContext context) {
    final states = <String>[
      if (cache.readyPages > 0) '${cache.readyPages} 页完整',
      if (cache.partialPages > 0) '${cache.partialPages} 页 partial',
      _formatBytes(cache.receivedBytes),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  cache.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(
                  '${cache.comicTitle} · ${cache.sourceId} · Exact 缓存',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                Text(
                  states.join(' · '),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (isConverting)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (onConvert != null)
            IconButton(
              key: downloadManagerConvertKey(cache.identity),
              tooltip: '转为下载任务',
              color: Theme.of(context).colorScheme.primary,
              onPressed: onConvert,
              icon: const Icon(Icons.download_outlined),
            ),
          if (isDeleting)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (onDelete != null)
            IconButton(
              key: downloadManagerClearCacheKey(cache.identity),
              tooltip: '清除 Exact 缓存',
              color: Theme.of(context).colorScheme.error,
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
    );
  }
}

final class _AutoCacheTaskTile extends StatelessWidget {
  const _AutoCacheTaskTile({
    required this.snapshot,
    this.isDeleting = false,
    this.isConverting = false,
    required this.onDelete,
    this.onConvert,
    super.key,
  });

  final ChapterDownloadSnapshot snapshot;
  final bool isDeleting;
  final bool isConverting;
  final VoidCallback onDelete;
  final VoidCallback? onConvert;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      snapshot.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      '${snapshot.comicTitle} · ${snapshot.sourceId} · 页面自动缓存',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (isConverting)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (onConvert != null)
                IconButton(
                  key: downloadManagerConvertKey(snapshot.identity),
                  tooltip: '转为下载任务',
                  color: Theme.of(context).colorScheme.primary,
                  onPressed: onConvert,
                  icon: const Icon(Icons.download_outlined),
                ),
              if (isDeleting)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                IconButton(
                  key: downloadManagerClearCacheKey(snapshot.identity),
                  tooltip: '清除本章缓存',
                  color: Theme.of(context).colorScheme.error,
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            snapshot.pinnedPages > 0
                ? '${snapshot.pinnedPages} 页已固定下载 · ${snapshot.autoCachedPages} 页自动缓存（共 ${snapshot.completedPages}/${snapshot.totalPages} 页）'
                    ' · ${_formatBytes(snapshot.receivedBytes)}'
                : '${snapshot.autoCachedPages > 0 ? snapshot.autoCachedPages : snapshot.completedPages}/${snapshot.totalPages} 页已缓存'
                    ' · ${_formatBytes(snapshot.receivedBytes)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

String _identity(ImportedLibraryEntry entry) => chapterDownloadIdentity(
      entry.chapter.sourceId,
      entry.chapter.comicId,
      entry.chapter.chapterId,
      entry.chapter.sourceRevision,
    );

String _chapterIdentity(String sourceId, String comicId, String chapterId) =>
    '$sourceId\u0000$comicId\u0000$chapterId';

int _phasePriority(ChapterDownloadPhase phase) => switch (phase) {
      ChapterDownloadPhase.downloading => 0,
      ChapterDownloadPhase.failed => 1,
      ChapterDownloadPhase.cancelled => 2,
      ChapterDownloadPhase.complete => 3,
      ChapterDownloadPhase.idle => 4,
    };

String _phaseLabel(ChapterDownloadPhase phase) => switch (phase) {
      ChapterDownloadPhase.idle => '未下载',
      ChapterDownloadPhase.downloading => '下载中',
      ChapterDownloadPhase.complete => '已下载',
      ChapterDownloadPhase.failed => '下载失败',
      ChapterDownloadPhase.cancelled => '已停止',
    };

String _wholeQueuePhaseLabel(WholeComicQueuePhase phase) => switch (phase) {
      WholeComicQueuePhase.queued => '排队中',
      WholeComicQueuePhase.running => '下载中',
      WholeComicQueuePhase.waitingForPolicy => '等待策略条件',
      WholeComicQueuePhase.requiresUserAction => '等待处理目录冲突',
      WholeComicQueuePhase.paused => '已暂停',
      WholeComicQueuePhase.complete => '已完成',
      WholeComicQueuePhase.failed => '失败',
      WholeComicQueuePhase.cancelled => '已取消',
    };

String _memoryKindSummary(ResourceCacheStats stats) {
  String item(ResourceCacheKind kind, String label) {
    final value = stats.forKind(kind);
    return '$label ${value.entries}/${_formatBytes(value.weight)}';
  }

  return <String>[
    item(ResourceCacheKind.imageBytes, '图片'),
    item(ResourceCacheKind.comicDetails, '详情'),
    item(ResourceCacheKind.chapterMetadata, '章节元数据'),
    item(ResourceCacheKind.searchResults, '搜索'),
  ].join(' · ');
}

String _formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  final kib = bytes / 1024;
  if (kib < 1024) {
    return '${kib.toStringAsFixed(kib < 10 ? 1 : 0)} KiB';
  }
  final mib = kib / 1024;
  if (mib < 1024) {
    return '${mib.toStringAsFixed(mib < 10 ? 1 : 0)} MiB';
  }
  final gib = mib / 1024;
  return '${gib.toStringAsFixed(gib < 10 ? 1 : 0)} GiB';
}

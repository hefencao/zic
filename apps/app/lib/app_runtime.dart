import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:downloads_bridge/downloads_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:network_bridge/network_bridge.dart';
import 'package:plugin_host_bridge/plugin_host_bridge.dart';
import 'package:plugin_host_bridge/runtime_service_entrypoint.dart'
    as plugin_runtime_service;
import 'package:resource_cache/resource_cache.dart';
import 'package:storage_bridge/storage_bridge.dart';
import 'package:telemetry/telemetry.dart';

import 'app_preferences.dart';
import 'chapter_download_directory.dart';
import 'artifact_presentation_file_bridge.dart';
import 'debug_trace.dart';
import 'demo_home.dart';
import 'home_library_session.dart';
import 'resettable_single_flight.dart';
import 'saf_store.dart';
import 'storage_root_access.dart';
import 'startup_platform.dart';
import 'webp_demo.dart';

@pragma('vm:entry-point')
Future<void> zicExternalPluginRuntimeServiceMain() =>
    plugin_runtime_service.zicExternalPluginRuntimeServiceMain();

Widget createStartupApp({
  bool firstFrameAlreadyRasterized = false,
  Future<String?>? startupApplicationSupportPath,
  String? startupApplicationSupportPathValue,
  bool startupStorageMetadataWarmed = false,
}) =>
    _BootstrapApp(
      firstFrameAlreadyRasterized: firstFrameAlreadyRasterized,
      startupApplicationSupportPath: startupApplicationSupportPath,
      startupApplicationSupportPathValue: startupApplicationSupportPathValue,
      startupStorageMetadataWarmed: startupStorageMetadataWarmed,
    );

/// Per-source physical download roots: sources with a user-configured
/// directory write new artifacts under that root; everything else keeps the
/// default store layout. Existing bytes stay readable through their indexed
/// absolute paths.
CacheLayout? Function(DownloadId id) sourceDownloadLayoutResolver(
  AppPreferencesController preferences,
) =>
    (id) {
      final directory =
          preferences.sourceDownloadDirectoryFor(id.content.sourceId);
      if (directory == null || directory.startsWith('saf://')) {
        return null;
      }
      return CacheLayout(directory);
    };

final Stopwatch _startupClock = Stopwatch()..start();

void _startupLog(String message) => debugPrint(
      '[zic-startup] elapsedMs=${_startupClock.elapsedMilliseconds} $message',
    );

Future<StorageRootAccessAliasProof?> _probeStorageRootAccessAlias(
  String treeUri,
) async {
  final proof = await probeAndroidStorageRootAccessAlias(treeUri);
  if (proof != null) {
    _startupLog('storage-root-access-alias-proven direct=${proof.direct.path}');
  }
  return proof;
}

void _persistStorageRootAccessAliasProof(_AppServices services) {
  final proofFuture = services.storageRootAccessAliasProof;
  final store = services.downloadComposition?.artifactStore;
  if (proofFuture == null || store == null) return;
  unawaited(Future<void>(() async {
    try {
      final proof = await proofFuture;
      if (proof == null) return;
      await store.registerStorageRootAccessAliasProof(proof);
      _startupLog('storage-root-access-alias-persisted');
    } on Object catch (error) {
      // Alias proof is an optional access optimization. A permission change or
      // service rebuild must never make the already-open SAF data path fail.
      debugPrint('storage-root alias persistence failed: $error');
    }
  }));
}

final class _BootstrapApp extends StatefulWidget {
  const _BootstrapApp({
    this.firstFrameAlreadyRasterized = false,
    this.startupApplicationSupportPath,
    this.startupApplicationSupportPathValue,
    this.startupStorageMetadataWarmed = false,
  });

  final bool firstFrameAlreadyRasterized;
  final Future<String?>? startupApplicationSupportPath;
  final String? startupApplicationSupportPathValue;
  final bool startupStorageMetadataWarmed;

  @override
  State<_BootstrapApp> createState() => _BootstrapAppState();
}

final class _BootstrapAppState extends State<_BootstrapApp>
    with WidgetsBindingObserver {
  late final AppPreferencesController _preferences;
  late final DebugTraceLog _debugTrace;
  late final HomeStartupTelemetry _startupTelemetry;
  late final Future<String> _storageRoot;
  late final ImportedLibraryStore _bootstrapLibrary;
  late final ResourceCacheCoordinator _bootstrapCache;
  late final HomeProjectionSnapshotStore _homeProjectionSnapshotStore;
  late final HomeServiceHandoff _serviceHandoff;
  _AppServices? _services;
  Timer? _servicesStartupTimer;
  Future<void>? _servicesOpening;
  bool _homeMounted = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _preferences = AppPreferencesController();
    // Resolve the platform support directory once and start it during the
    // bootstrap turn. The first Android startup-channel call can otherwise
    // take hundreds of milliseconds and block the snapshot before Home can
    // project its previous state.
    final startupApplicationSupportPath =
        widget.startupApplicationSupportPath;
    final startupApplicationSupportPathValue =
        widget.startupApplicationSupportPathValue;
    if (startupApplicationSupportPathValue != null) {
      final storageRoot = '$startupApplicationSupportPathValue/zic';
      // The Android entrypoint argument is already a concrete local path.
      // Keep this branch synchronous so the snapshot path cannot inherit a
      // delayed Future continuation from the startup turn.
      _storageRoot = Future<String>.value(storageRoot);
      _homeProjectionSnapshotStore = HomeProjectionSnapshotStore.atPath(
        '$storageRoot/home_projection_snapshot.json',
        metadataAlreadyProbed: widget.startupStorageMetadataWarmed,
      );
      // The bootstrap Home must probe the same durable response cache that
      // the later service composition adopts. Otherwise warm covers requested
      // before handoff are forced to wait for external plugin activation.
      _bootstrapCache = createAppResourceCache(storageRoot: storageRoot);
    } else {
      _storageRoot = startupApplicationSupportPath == null
          ? getDefaultZicStorageRoot(
              applicationSupportPath: getStartupApplicationSupportPath,
            )
          : getDefaultZicStorageRoot(
              applicationSupportPath: () => startupApplicationSupportPath,
            );
      _homeProjectionSnapshotStore = createHomeProjectionSnapshotStore(
        storageRoot: () => _storageRoot,
      );
      _bootstrapCache = ResourceCacheCoordinator();
    }
    _debugTrace = DebugTraceLog();
    WidgetsBinding.instance.addObserver(this);
    _bootstrapLibrary = createLazyImportedLibraryStore(
      storageRoot: () => _storageRoot,
    );
    _serviceHandoff = HomeServiceHandoff()
      ..setBootstrapLibrary(_bootstrapLibrary)
      ..setBootstrapCache(_bootstrapCache)
      ..setChapterDownloadRelay(changeChapterDownloadDirectory)
      ..setEnsureCoreServices(_ensureDurableServices);
    // Begin both small durable reads before durable services are opened.
    // HomeLibrarySession joins the in-flight snapshot read later, while
    // preferences can finish before the durable composition is adopted.
    unawaited(_homeProjectionSnapshotStore.read());
    _preferencesReady = _attachPreferencesEarly();
    _preferences.addListener(_syncDebugTrace);
    _syncDebugTrace();
    _startupTelemetry = HomeStartupTelemetry(
      clock: SystemClock(),
      sink: MultiTraceSink(<TraceSink>[
        _debugTrace,
        if (kDebugMode)
          CallbackTraceSink((event) => debugPrint(event.toJsonLine())),
      ]),
    );
    unawaited(_recordNativeStartupTimeline());
    if (widget.firstFrameAlreadyRasterized) {
      _homeMounted = true;
      _startupLog('home-mount-ready mode=already-rasterized');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed) return;
        _startupTelemetry.bootstrapPresented();
        _scheduleDurableServicesWindow();
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed) return;
        _startupLog('runtime-bootstrap-frame-built');
        // Keep durable services and feature plugins deferred past the first
        // Home frame.
        unawaited(_scheduleDurableServicesAfterFirstRaster());
      });
    }
  }

  late final Future<void> _preferencesReady;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    final clock = SystemClock();
    _debugTrace.record(
      traceEvent(
        clock: clock,
        sessionId: 'app-lifecycle',
        kind: TraceEventKind.appLifecycle,
        payload: <String, Object?>{
          'stage': 'dart',
          'state': state.name,
        },
      ),
    );
    unawaited(_recordLifecycleSchedulingSnapshot(state));
  }

  Future<void> _recordLifecycleSchedulingSnapshot(
    AppLifecycleState state,
  ) async {
    final snapshot = await getAndroidSchedulingSnapshot();
    if (_disposed || snapshot == null) return;
    _debugTrace.record(
      traceEvent(
        clock: SystemClock(),
        sessionId: 'app-lifecycle',
        kind: TraceEventKind.appLifecycle,
        payload: <String, Object?>{
          'stage': 'android-scheduling',
          'state': state.name,
          ...snapshot,
        },
      ),
    );
  }

  Future<void> _recordNativeStartupTimeline() async {
    final timeline = await getNativeStartupTimeline();
    if (_disposed || timeline == null) return;
    _debugTrace.record(
      traceEvent(
        clock: SystemClock(),
        sessionId: 'home-startup',
        kind: TraceEventKind.platformStartupTimeline,
        payload: timeline,
      ),
    );
  }

  Future<void> _attachPreferencesEarly() async {
    final root = await _storageRoot;
    final preferencePath = '$root/app_preferences.json';
    _startupLog('preferences-preload-start');
    try {
      await _preferences.attach(
        read: () => readJsonObjectFile(preferencePath),
        write: (values) => writeJsonObjectFile(preferencePath, values),
      );
    } on Object catch (error) {
      debugPrint('app preferences unavailable: $error');
    }
    _startupLog('preferences-preload-complete');
  }

  Future<void> _scheduleDurableServicesAfterFirstRaster() async {
    // A Dart post-frame callback runs before Android has necessarily presented
    // the Flutter surface. Reader-triggered cache/index work can therefore
    // still turn the nominal bootstrap frame into a multi-second black screen
    // if admitted here. On Android, wait for FlutterActivity's actual
    // onFlutterUiDisplayed boundary. The platform helper is bounded and other
    // platforms keep the existing post-frame fallback.
    final platformDisplayed = await waitForFirstFlutterUiDisplayed();
    if (_disposed) return;
    _startupLog(
      platformDisplayed
          ? 'runtime-bootstrap-platform-ui-displayed'
          : 'runtime-bootstrap-platform-ui-display-fallback',
    );
    _startupLog('runtime-bootstrap-frame-presented');
    _startupTelemetry.bootstrapPresented();
    if (!_homeMounted) {
      _startupLog('home-mount-start mode=bootstrap');
      setState(() => _homeMounted = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed) return;
        _scheduleDurableServicesWindow();
      });
      return;
    }
    _scheduleDurableServicesWindow();
  }

  void _scheduleDurableServicesWindow() {
    if (_disposed || _servicesStartupTimer != null) return;
    // The caller reaches this point after a Home frame. A zero-delay timer
    // keeps the open off that frame's callback while avoiding an artificial
    // visibility delay for an installation that already has durable state.
    _servicesStartupTimer = Timer(Duration.zero, () {
      _servicesStartupTimer = null;
      if (_disposed) return;
      _startupLog('visible-home-window-complete');
      unawaited(_openDurableServices());
    });
  }

  Future<void> _ensureDurableServices() async {
    if (_disposed) return;
    if (_services?.hasCoreServices == true) return;
    await _openDurableServices(forceDurable: true);
    if (_services?.hasCoreServices != true) {
      throw StateError('durable download services are unavailable');
    }
  }

  Future<void> _openDurableServices({bool forceDurable = false}) async {
    if (_disposed || _services?.hasCoreServices == true) {
      return Future<void>.value();
    }
    final existing = _servicesOpening;
    if (existing != null) {
      await existing;
      // A first-frame background open may have intentionally observed an
      // empty install and returned the bootstrap-only composition. An
      // explicit download arriving during that window must upgrade the same
      // handoff to a forced durable open rather than surfacing a transient
      // "services unavailable" error.
      if (forceDurable && _services?.hasCoreServices != true && !_disposed) {
        return _openDurableServices(forceDurable: true);
      }
      return;
    }
    late final Future<void> opening;
    opening = _openDurableServicesOnce(forceDurable: forceDurable).whenComplete(() {
      if (identical(_servicesOpening, opening)) {
        _servicesOpening = null;
      }
    });
    _servicesOpening = opening;
    await opening;
  }

  Future<void> _openDurableServicesOnce({bool forceDurable = false}) async {
    if (_disposed || _services?.hasCoreServices == true) return;
    final previous = _services;
    _startupLog('services-open-start');
    _startupTelemetry.servicesOpenStarted();
    final services = await _openServices(
      _startupTelemetry,
      _preferences,
      storageRoot: _storageRoot,
      preferencesReady: _preferencesReady,
      bootstrapLibrary: _bootstrapLibrary,
      forceDurable: forceDurable,
      responseCache: _serviceHandoff.cacheCoordinator?.responses,
      debugTrace: _debugTrace,
    );
    if (_disposed) {
      if (services.hasCoreServices) {
        unawaited(services.close());
      }
      return;
    }
    previous?.transferExternalPluginOwnershipTo(services);
    _services = services;
    _publishExternalPluginsWhenReady(services);
    if (!services.hasCoreServices) {
      // Empty installs deliberately remain memory-backed. In particular, do
      // not create SQLite/WAL files merely because Home was opened. The first
      // explicit durable operation is responsible for crossing that boundary.
      // Plugin management is an independent optional capability: publish its
      // loader and durable root without replacing the bootstrap services.
      _startupLog('services-open-skipped-empty-state');
      _serviceHandoff.updateDeferredCapabilities(
        externalPlugins: services.externalPlugins,
        externalPluginLoader: () => _ensureExternalPlugins(services),
        platformEnvironmentLoader: services.ensurePlatformEnvironment,
        storageRoot: services.storageRoot,
      );
      return;
    }
    _startupLog('services-open-complete');
    // A post-frame callback does not schedule a frame by itself. If the
    // service open completes after the last frame of an otherwise idle app,
    // waiting for that callback leaves Home on the empty memory projection
    // until the next user gesture happens to schedule a frame.
    if (_disposed) {
      unawaited(services.close());
      return;
    }
    _startupLog('home-mount-start mode=durable');
    _serviceHandoff.updateServices(
      libraryStore: services.libraryStore,
      chapterDownloads: services.chapterDownloads,
      downloadComposition: services.downloadComposition,
      wholeComicDownloads: services.wholeComicDownloads,
      cacheCoordinator: services.cacheCoordinator,
      externalPlugins: services.externalPlugins,
      externalPluginLoader: () => _ensureExternalPlugins(services),
      platformEnvironmentLoader: services.ensurePlatformEnvironment,
      ensureCoreServices: _ensureDurableServices,
      storageRoot: services.storageRoot,
      persistHomeProjectionSnapshot: true,
    );
  }

  void _publishExternalPluginsWhenReady(_AppServices services) {
    final ready = services.externalPluginsReady;
    unawaited(ready.then<void>((_) {
      if (_disposed || !identical(_services, services)) {
        return;
      }
      _serviceHandoff.updateExternalPlugins(services.externalPlugins);
    }));
  }

  Future<ExternalPluginController?> _ensureExternalPlugins(
    _AppServices services,
  ) async {
    final controller = await services.ensureExternalPlugins(
      telemetry: _startupTelemetry,
      preferences: _preferences,
    );
    if (mounted && identical(_services, services)) {
      _serviceHandoff.updateExternalPlugins(controller);
    }
    return controller;
  }

  /// Applies a new chapter-download directory chosen in settings.
  ///
  /// Returns a user-facing error message, or `null` on success. The intent is
  /// persisted before any byte moves so an interrupted attempt is completed at
  /// the next startup by [settleChapterDownloadDirectory]. Index and artifact
  /// bytes always move together; the string preference alone never relocates
  /// the store.
  Future<String?> changeChapterDownloadDirectory({
    String? directory,
    required bool migrateFiles,
  }) async {
    final root = await _storageRoot;
    final chapterMetadataPath = defaultChapterDownloadMetadataPath(root);
    if (_services?.hasCoreServices != true) {
      try {
        await _ensureDurableServices();
      } on Object {
        return '存储尚未就绪，请稍后重试';
      }
    }
    final services = _services;
    if (services == null) {
      return '存储尚未就绪，请稍后重试';
    }
    // SAF roots are used verbatim: no Venera nested-store rules, no POSIX
    // resolution, and file migration across schemes is not supported yet.
    final safTarget = directory != null && directory.startsWith('saf://');
    String target;
    try {
      if (safTarget) {
        target = directory;
      } else {
        target = directory == null
            ? defaultChapterDownloadDirectory(root)
            : await resolveChapterDownloadDirectory(directory);
      }
    } on Object catch (error) {
      debugPrint('chapter-download directory resolve failed: $error');
      return '无法使用所选目录';
    }
    if (safTarget && migrateFiles) {
      migrateFiles = false;
    }
    final previousOverride = _preferences.chapterDownloadDirectoryOverride;
    final current = previousOverride ??
        defaultChapterDownloadDirectory(root);
    if (_isSamePath(target, current)) {
      _preferences.setChapterDownloadDirectoryOverride(
        directory == null ? null : target,
      );
      _preferences.setChapterDownloadDirectoryPendingMoveFrom(null);
      return null;
    }
    if (!services.hasCoreServices) {
      // Memory-mode install: no download store owns durable jobs, so a
      // directory change here would split the recorded path from where the
      // next launch actually opens its store. Refuse custom targets and let
      // the default reset through only because it removes a stale override.
      if (directory != null) {
        return '下载服务未运行（内存模式），无法切换到自定义目录；请重启应用后再试';
      }
      _preferences.setChapterDownloadDirectoryOverride(null);
      _preferences.setChapterDownloadDirectoryPendingMoveFrom(null);
      return null;
    }

    final queue = services.wholeComicDownloads;
    final busyJobs =
        queue?.snapshot.jobs.any((job) => job.isActive) ?? false;
    if (busyJobs) {
      return '有正在进行的整本下载任务，请先暂停或等待完成';
    }
    // Idle Reader re-entry sessions intentionally retain a transfer consumer
    // for up to two minutes. They are not active UI readers and must not block
    // an explicit storage-root switch. Drain only that bounded idle pool first;
    // an actually mounted Reader remains leased and therefore still trips the
    // consumer check below.
    await drainDefaultRetainedReaderSessions();
    final composition = services.downloadComposition;
    if (composition != null && composition.transferRuntime.hasConsumers) {
      return '阅读器正在使用下载内容，请稍后再试';
    }
    final hasStoreContent = chapterDownloadStoreHasContent(current);
    if (migrateFiles && hasStoreContent && _isSameOrNested(current, target)) {
      return '新目录不能包含或嵌套于当前下载目录';
    }
    // Android scoped storage can allow listing/creating a directory while
    // still denying file writes; probe once so the switch fails here with a
    // clear reason instead of degrading downloads to memory later. SAF roots
    // are validated by their persisted document-tree grant instead.
    if (directory != null && !target.startsWith('saf://')) {
      try {
        await probeChapterDownloadDirectoryWritable(target);
      } on Object catch (error) {
        debugPrint('chapter-download directory write probe failed: $error');
        return '所选目录不可写：$error';
      }
    }

    // Persist the intent first. If anything below crashes, the next startup
    // completes the move from the recorded source directory.
    _preferences.setChapterDownloadDirectoryOverride(
      directory == null ? null : target,
    );
    _preferences.setChapterDownloadDirectoryPendingMoveFrom(
      migrateFiles && hasStoreContent ? current : null,
    );
    await _preferences.flush();

    Object? closeFailure;
    try {
      await services.checkpointTransferPartials();
      if (queue != null) {
        await queue.close();
      }
      await services.cacheCoordinator?.close();
      // Throws while Reader transfer consumers are still attached; nothing
      // has moved yet at that point.
      await services.downloadComposition?.close();
    } on Object catch (error) {
      closeFailure = error;
    }
    if (closeFailure != null) {
      debugPrint('download service close for directory change failed: '
          '$closeFailure');
      _preferences.setChapterDownloadDirectoryOverride(previousOverride);
      _preferences.setChapterDownloadDirectoryPendingMoveFrom(null);
      final rebuilt = await _rebuildDownloadServices(
        storageRoot: root,
        downloadDirectory: current,
        previous: services,
      );
      if (rebuilt != null) {
        _publishDegradedServices(storageRoot: root);
      }
      return '下载服务忙，目录暂未切换';
    }

    Object? moveError;
    final pendingFrom = _preferences.chapterDownloadDirectoryPendingMoveFrom;
    if (pendingFrom != null) {
      try {
        final report = await moveChapterDownloadStore(
          from: pendingFrom,
          to: target,
          metadataDbPath: chapterMetadataPath,
        );
        _startupLog(
          'chapter-download-move-complete files=${report.movedFileCount} '
          'records=${report.rewrittenRecordCount} to=$target',
        );
      } on Object catch (error) {
        moveError = error;
        debugPrint('chapter-download move failed: $error');
      }
    }
    // If the move failed before the source index was moved, reopening the
    // target would create a fresh cache.sqlite there. That empty database
    // would then conflict with the source database on the next startup retry,
    // permanently stranding the pending move. Keep the source authoritative
    // until recovery moves it successfully; if the source index is already
    // gone, the target is the only authoritative side after a partial move.
    final rebuildDirectory = moveError == null
        ? target
        : pendingFrom != null && chapterDownloadStoreHasContent(pendingFrom)
            ? pendingFrom
            : target;
    final rebuildError = await _rebuildDownloadServices(
      storageRoot: root,
      downloadDirectory: rebuildDirectory,
      previous: services,
    );
    if (rebuildError != null) {
      _publishDegradedServices(storageRoot: root);
      return '目录已更新，但下载服务重启失败：$rebuildError';
    }
    if (moveError == null) {
      _preferences.setChapterDownloadDirectoryPendingMoveFrom(null);
    }
    return moveError == null ? null : '目录已切换，但部分文件迁移失败：$moveError';
  }

  /// Reopens the download-owned durable services after a store move or an
  /// aborted change. The library store and external plugins stay untouched;
  /// they do not live under the download directory. Returns the rebuild
  /// failure (null on success) so callers can surface the real cause.
  Future<Object?> _rebuildDownloadServices({
    required String storageRoot,
    required String downloadDirectory,
    required _AppServices previous,
  }) async {
    try {
      final safOverride = chapterDownloadSafTreeUri(downloadDirectory);
      defaultDownloadResourceCoordinator.speculativeEncodedReadBudget
          .updateLimitBytes(
        _preferences.readerPrefetchReadBudgetMiB * 1024 * 1024,
      );
      final composition = await PersistentDownloadComposition.open(
        storageRoot,
        directory: safOverride == null ? downloadDirectory : null,
        indexPath: defaultChapterDownloadMetadataPath(storageRoot),
        layoutResolver: sourceDownloadLayoutResolver(_preferences),
        userAgentProvider: () => _preferences.networkUserAgent,
        transferNet: defaultDownloadResourceCoordinator.networkLane,
        localReadScheduler: defaultDownloadResourceCoordinator.localReadScheduler,
        storageWriteScheduler: defaultDownloadResourceCoordinator.storageWriteScheduler,
        speculativeEncodedReadBudget:
            defaultDownloadResourceCoordinator.speculativeEncodedReadBudget,
        safTreeIo: safOverride == null
            ? null
            : _SafTreeIoAdapter(SafStore(treeUri: safOverride)),
        safTreeUri: safOverride,
        presentationFileLeaseFactory:
            const _AndroidArtifactPresentationFileLeaseFactory(),
        traceSink: _debugTrace,
      );
      final cacheCoordinator = createAppResourceCache(
        storageRoot: storageRoot,
        artifacts: composition.artifactStore,
        onPersistenceError: (error, stackTrace) {
          debugPrint('durable response cache failed: $error');
        },
      )..updateMaintenancePolicy(
          ResourceCacheMaintenancePolicy.forArtifactLimitBytes(
            _preferences.cacheLimitMb * 1024 * 1024,
          ),
        );
      final platformEnvironment = PlatformWholeComicQueueEnvironment();
      final wholeComicDownloads = createPersistentWholeComicDownloadQueue(
        path: '$storageRoot/whole_comic_queue.json',
        downloads: composition.chapterDownloads,
        environment: platformEnvironment,
        ownsEnvironment: true,
        storageRootId: composition.artifactStore.storageRootId,
      );
      final services = _AppServices(
        libraryStore: previous.libraryStore,
        ownsLibraryStore: previous.ownsLibraryStore,
        chapterDownloads: composition.chapterDownloads,
        downloadComposition: composition,
        wholeComicDownloads: wholeComicDownloads,
        cacheCoordinator: cacheCoordinator,
        platformEnvironment: platformEnvironment,
        storageRoot: storageRoot,
        storageRootAccessAliasProof: safOverride == null
          ? null
          : _probeStorageRootAccessAlias(safOverride),
      );
      _persistStorageRootAccessAliasProof(services);
      previous.transferExternalPluginOwnershipTo(services);
      _services = services;
      _publishExternalPluginsWhenReady(services);
      _serviceHandoff.updateServices(
        libraryStore: services.libraryStore,
        chapterDownloads: services.chapterDownloads,
        downloadComposition: services.downloadComposition,
        wholeComicDownloads: services.wholeComicDownloads,
        cacheCoordinator: services.cacheCoordinator,
        externalPlugins: services.externalPlugins,
        externalPluginLoader: () => _ensureExternalPlugins(services),
        platformEnvironmentLoader: services.ensurePlatformEnvironment,
        ensureCoreServices: _ensureDurableServices,
        storageRoot: services.storageRoot,
        persistHomeProjectionSnapshot: true,
      );
      _startupLog('download-services-rebuilt-at $downloadDirectory');
      return null;
    } on Object catch (error, stackTrace) {
      _startupLog('download-services-rebuild-failed-at $downloadDirectory '
          'error=$error');
      debugPrint('download service rebuild failed: $error $stackTrace');
      return error;
    }
  }

  void _publishDegradedServices({required String storageRoot}) {
    final previous = _services;
    final degraded = _AppServices(
      libraryStore: previous?.libraryStore,
      ownsLibraryStore: previous?.ownsLibraryStore ?? false,
      storageRoot: storageRoot,
    );
    previous?.transferExternalPluginOwnershipTo(degraded);
    _services = degraded;
    _publishExternalPluginsWhenReady(degraded);
    _startupLog('download-services-degraded-memory');
    _serviceHandoff.updateDeferredCapabilities(
      externalPlugins: degraded.externalPlugins,
      externalPluginLoader: () => _ensureExternalPlugins(degraded),
      platformEnvironmentLoader: degraded.ensurePlatformEnvironment,
      storageRoot: storageRoot,
    );
  }

  bool _isSamePath(String a, String b) => isSameDirectoryPath(a, b);

  bool _isSameOrNested(String a, String b) =>
      isSameOrNestedDirectoryPath(a, b);

  void _syncDebugTrace() {
    _debugTrace.enabled =
        _preferences.debugModeEnabled && _preferences.debugTraceEnabled;
  }

  @override
  void dispose() {
    _disposed = true;
    _servicesStartupTimer?.cancel();
    _servicesStartupTimer = null;
    _preferences.removeListener(_syncDebugTrace);
    WidgetsBinding.instance.removeObserver(this);
    final services = _services;
    if (services != null) {
      unawaited(services.close());
    }
    unawaited(_bootstrapLibrary.close());
    unawaited(_preferences.flush());
    _preferences.dispose();
    _debugTrace.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return App(
      homeProjectionSnapshotStore: _homeProjectionSnapshotStore,
      persistHomeProjectionSnapshot: false,
      serviceHandoff: _serviceHandoff,
      persistMissingPreferences: false,
      startupTelemetry: _startupTelemetry,
      preferences: _preferences,
      debugTrace: _debugTrace,
    );
  }
}

final class _AppServices {
  _AppServices({
    this.libraryStore,
    this.ownsLibraryStore = false,
    this.chapterDownloads,
    this.downloadComposition,
    this.wholeComicDownloads,
    this.cacheCoordinator,
    this.platformEnvironment,
    this.storageRoot,
    this.storageRootAccessAliasProof,
  });

  final ImportedLibraryStore? libraryStore;
  final bool ownsLibraryStore;
  final ManagedChapterDownloadService? chapterDownloads;
  final PersistentDownloadComposition? downloadComposition;
  final WholeComicDownloadQueue? wholeComicDownloads;
  final ResourceCacheCoordinator? cacheCoordinator;
  final PlatformWholeComicQueueEnvironment? platformEnvironment;
  final String? storageRoot;
  final Future<StorageRootAccessAliasProof?>? storageRootAccessAliasProof;

  bool get hasCoreServices =>
      libraryStore != null ||
      chapterDownloads != null ||
      downloadComposition != null ||
      wholeComicDownloads != null ||
      cacheCoordinator != null;

  /// Set once the deferred external plugin host finishes opening. Local
  /// home content must not wait for this; the UI mounts on core services and
  /// picks up external sources through a later widget update.
  ExternalPluginController? externalPlugins;
  Future<void> externalPluginsReady = Future<void>.value();
  final ResettableSingleFlight<ExternalPluginController?>
      _externalPluginOpening =
      ResettableSingleFlight<ExternalPluginController?>();
  Future<void>? _platformEnvironmentOpening;
  _AppServices? _externalPluginSuccessor;
  bool _closed = false;
  Future<void>? _closing;
  Future<void>? _partialCheckpoint;

  Future<void> ensurePlatformEnvironment() async {
    if (_closed) return;
    final environment = platformEnvironment;
    if (environment == null) return;
    final existing = _platformEnvironmentOpening;
    if (existing != null) {
      await existing;
      return;
    }
    late final Future<void> opening;
    opening = Future<void>(() async {
      try {
        await attachAndroidPlugin('runtime_bridge');
        await environment.initialize();
      } on Object catch (error) {
        // The queue starts with its conservative assumed environment. A
        // platform signal is an optional refinement and must not block an
        // explicit download action if the bridge is unavailable.
        debugPrint('runtime download policy signals unavailable: $error');
      }
    });
    _platformEnvironmentOpening = opening;
    await opening;
  }

  ExternalPluginController? get _currentExternalPluginController =>
      _externalPluginSuccessor?._currentExternalPluginController ??
      externalPlugins;

  Future<ExternalPluginController?> ensureExternalPlugins({
    required HomeStartupTelemetry telemetry,
    required AppPreferencesController preferences,
  }) {
    final successor = _externalPluginSuccessor;
    if (successor != null) {
      return successor.ensureExternalPlugins(
        telemetry: telemetry,
        preferences: preferences,
      );
    }
    final current = externalPlugins;
    if (current != null) {
      return Future<ExternalPluginController?>.value(current);
    }
    final opening = _externalPluginOpening.active;
    if (opening != null) {
      return opening;
    }
    final root = storageRoot;
    if (root == null || _closed) {
      return Future<ExternalPluginController?>.value();
    }
    // A failed optional open must not poison explicit source-management
    // retries. Settle the previous attempt before starting the next one, but
    // do not propagate its failure as the result of every later attempt.
    final background = externalPluginsReady.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    final forcedOpening = _externalPluginOpening.run(
      () => background.then<ExternalPluginController?>((_) async {
        // Once this predecessor flight exists, keep it as the physical opener.
        // A successor joins this ready tail during ownership transfer; asking
        // the successor to ensure from inside this flight would make each side
        // wait on the other. The opened controller is forwarded by
        // _acceptExternalPluginController instead.
        if (_closed || externalPlugins != null) {
          return externalPlugins;
        }
        await _attachExternalPlugins(
          telemetry,
          this,
          root,
          () => preferences.networkUserAgent,
          telemetry.nowMicros(),
          force: true,
        );
        return _currentExternalPluginController;
      }),
    );
    externalPluginsReady = forcedOpening.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return forcedOpening;
  }

  void transferExternalPluginOwnershipTo(_AppServices target) {
    if (identical(this, target)) {
      return;
    }
    final successor = _externalPluginSuccessor;
    if (successor != null) {
      successor.transferExternalPluginOwnershipTo(target);
      return;
    }
    _externalPluginSuccessor = target;
    target._joinExternalPluginReady(externalPluginsReady);
    final controller = externalPlugins;
    externalPlugins = null;
    if (controller != null) {
      unawaited(target._acceptExternalPluginController(controller));
    }
  }

  void _joinExternalPluginReady(Future<void> inherited) {
    final current = externalPluginsReady;
    if (identical(current, inherited)) {
      return;
    }
    externalPluginsReady = Future.wait<void>(
      <Future<void>>[current, inherited],
    ).then<void>((_) {});
  }

  Future<bool> _acceptExternalPluginController(
    ExternalPluginController controller,
  ) {
    final successor = _externalPluginSuccessor;
    if (successor != null) {
      return successor._acceptExternalPluginController(controller);
    }
    if (!_closed && externalPlugins == null) {
      externalPlugins = controller;
      return Future<bool>.value(true);
    }
    if (identical(externalPlugins, controller)) {
      return Future<bool>.value(true);
    }
    return controller.close().then<bool>((_) => false);
  }

  Future<void> checkpointTransferPartials() {
    final composition = downloadComposition;
    if (composition == null || _closed) return Future<void>.value();
    final running = _partialCheckpoint;
    if (running != null) return running;
    late final Future<void> checkpoint;
    checkpoint = composition.transferRuntime
        .checkpointPartials(reason: 'app-runtime-safety-checkpoint')
        .whenComplete(() {
      if (identical(_partialCheckpoint, checkpoint)) {
        _partialCheckpoint = null;
      }
    });
    _partialCheckpoint = checkpoint;
    return checkpoint;
  }

  Future<void> close({
    Duration settleTimeout = const Duration(minutes: 1),
    Future<void> Function(ImportedLibraryStore? libraryStore)?
        beforeLibraryClose,
  }) {
    final existing = _closing;
    if (existing != null) return existing;
    late final Future<void> closing;
    closing = _close(
      settleTimeout: settleTimeout,
      beforeLibraryClose: beforeLibraryClose,
    );
    _closing = closing;
    return closing;
  }

  Future<void> _close({
    required Duration settleTimeout,
    Future<void> Function(ImportedLibraryStore? libraryStore)?
        beforeLibraryClose,
  }) async {
    if (_closed) {
      return;
    }
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      await checkpointTransferPartials();
    } on Object catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    _closed = true;
    try {
      await shutdownDefaultLocalMediaPipeline();
    } on Object catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    // The deferred plugin open may still be in flight; settle it before the
    // close pass so a late controller cannot leak after teardown.
    try {
      await externalPluginsReady.timeout(settleTimeout);
    } on Object catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    try {
      await _platformEnvironmentOpening?.timeout(settleTimeout);
    } on Object catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    for (final close in <Future<void> Function()>[
      if (wholeComicDownloads != null) wholeComicDownloads!.close,
      if (cacheCoordinator != null) cacheCoordinator!.close,
      if (downloadComposition != null)
        downloadComposition!.close
      else if (chapterDownloads != null)
        chapterDownloads!.close,
      if (externalPlugins != null) externalPlugins!.close,
    ]) {
      try {
        await close();
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (beforeLibraryClose != null) {
      try {
        await beforeLibraryClose(libraryStore);
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (ownsLibraryStore) {
      try {
        await libraryStore?.close();
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }
}

/// Binds the app-side SAF channel client to the downloads package's
/// transport interface. Lives here because platform channels are an app
/// concern; the package stays testable with fakes.
class _SafTreeIoAdapter
    implements
        SafTreeIo,
        SafTreeRandomRead,
        SafTreeReadPrewarmer,
        SafTreeAtomicReplace {
  _SafTreeIoAdapter(this._store);

  final SafStore _store;

  @override
  Future<bool> prewarmReadProvider() =>
      _readOperation<bool>('prewarm-read-provider', _store.prewarmRecentRead);

  Future<T> _readOperation<T>(
    String operation,
    Future<T> Function() action,
  ) async {
    try {
      return await action();
    } on PlatformException catch (error) {
      throw SafTreeAccessFailure(
        kind: switch (error.code) {
          'saf-access-denied' => ArtifactReadFailureKind.accessDenied,
          'saf-missing' => ArtifactReadFailureKind.missing,
          'saf-stale-locator' => ArtifactReadFailureKind.staleLocator,
          _ => ArtifactReadFailureKind.ioFailure,
        },
        operation: operation,
        cause: error,
      );
    }
  }

  @override
  Future<int?> open(
    String relativePath, {
    SafWriteMode mode = SafWriteMode.read,
  }) {
    Future<int?> operation() => _store.open(
          relativePath,
          mode: switch (mode) {
            SafWriteMode.read => SafMode.read,
            SafWriteMode.writeAppend => SafMode.writeAppend,
            SafWriteMode.writeTruncate => SafMode.writeTruncate,
          },
        );
    return mode == SafWriteMode.read
        ? _readOperation<int?>('open', operation)
        : operation();
  }

  @override
  Future<Uint8List> read(int handle, int length) =>
      _readOperation<Uint8List>('read', () => _store.read(handle, length));

  @override
  Future<Uint8List> readAt(int handle, int position, int length) =>
      _readOperation<Uint8List>(
        'readAt',
        () => _store.readAt(handle, position, length),
      );

  @override
  Future<void> write(int handle, Uint8List bytes) =>
      _store.write(handle, bytes);

  @override
  Future<void> seek(int handle, int position) =>
      _readOperation<void>('seek', () => _store.seek(handle, position));

  @override
  Future<void> close(int handle) => _store.close(handle);

  @override
  Future<bool> delete(String relativePath) => _store.delete(relativePath);

  @override
  Future<bool> exists(String relativePath) =>
      _readOperation<bool>('exists', () => _store.exists(relativePath));

  @override
  Future<bool> rename(String relativePath, String newRelativePath) =>
      _store.rename(relativePath, newRelativePath);

  @override
  Future<bool> replace(String relativePath, String newRelativePath) =>
      _store.replace(relativePath, newRelativePath);

  @override
  Future<int?> length(int handle) =>
      _readOperation<int?>('length', () => _store.length(handle));

  @override
  Future<List<SafTreeFile>> list(String relativePath) async {
    final entries = await _store.list(relativePath);
    return entries
        .map(
          (e) => SafTreeFile(
            name: e.name,
            isDirectory: e.isDirectory,
            length: e.length,
          ),
        )
        .toList();
  }
}

final class _AndroidArtifactPresentationFileLeaseFactory
    implements ArtifactPresentationFileLeaseFactory {
  const _AndroidArtifactPresentationFileLeaseFactory();

  static const int _metadataProbeBytes = 64 * 1024;
  static final AndroidArtifactPresentationFileBridge _bridge =
      AndroidArtifactPresentationFileBridge();

  @override
  Future<ArtifactCachePresentationFileLease?> open(
    String accessLocator, {
    required int expectedLength,
  }) async {
    if (!AndroidArtifactPresentationFileBridge.isSupported) return null;
    AndroidArtifactPresentationFileHandle? handle;
    try {
      final saf = parseSafRecordPath(accessLocator);
      handle = saf == null
          ? await _bridge.openDirect(accessLocator)
          : await _bridge.openSaf(
              treeUri: saf.treeUri,
              relativePath: saf.relativePath,
            );
    } on PlatformException catch (error) {
      throw ArtifactReadFailure(
        kind: switch (error.code) {
          'saf-access-denied' => ArtifactReadFailureKind.accessDenied,
          'saf-missing' => ArtifactReadFailureKind.missing,
          'saf-stale-locator' => ArtifactReadFailureKind.staleLocator,
          _ => ArtifactReadFailureKind.ioFailure,
        },
        accessLocator: accessLocator,
        failedOffset: 0,
        bytesEmitted: 0,
        expectedLength: expectedLength,
        cause: error,
      );
    }
    if (handle == null) return null;
    if (handle.length != expectedLength) {
      await _bridge.close(handle.handle);
      throw ArtifactReadFailure(
        kind: ArtifactReadFailureKind.lengthChanged,
        accessLocator: accessLocator,
        failedOffset: 0,
        bytesEmitted: 0,
        expectedLength: expectedLength,
        observedLength: handle.length,
      );
    }
    final prefix = await tryReadEncodedFilePrefix(
      FileEncodedResourceSource(
        path: handle.path,
        lengthInBytes: handle.length,
        origin: EncodedResourceOrigin.durableCacheFile,
      ),
      maxBytes: _metadataProbeBytes,
    );
    if (prefix == null) {
      await _bridge.close(handle.handle);
      return null;
    }
    final dimensions = sniffImageDimensionsFromBytes(prefix);
    var released = false;
    return ArtifactCachePresentationFileLease(
      path: handle.path,
      length: handle.length,
      width: dimensions?.width,
      height: dimensions?.height,
      release: () async {
        if (released) return;
        released = true;
        await _bridge.close(handle!.handle);
      },
    );
  }
}

Future<_AppServices> _openServices(
  HomeStartupTelemetry telemetry,
  AppPreferencesController preferences, {
  Future<String>? storageRoot,
  Future<void>? preferencesReady,
  ImportedLibraryStore? bootstrapLibrary,
  ResourceCacheManager? responseCache,
  TraceSink? debugTrace,
  bool forceDurable = false,
}) async {
  ImportedLibraryStore? libraryStore;
  ManagedChapterDownloadService? chapterDownloads;
  PersistentDownloadComposition? downloadComposition;
  WholeComicDownloadQueue? wholeComicDownloads;
  ResourceCacheCoordinator? cacheCoordinator;
  String? resolvedStorageRoot;
  var ownsLibraryStore = true;
  try {
    final openedAt = telemetry.nowMicros();
    var stageStarted = telemetry.nowMicros();
    final storageRootClock = Stopwatch()..start();
    _startupLog('storage-root-resolve-start');
    final root = await (storageRoot ??
        getDefaultZicStorageRoot(
          applicationSupportPath: getStartupApplicationSupportPath,
        ));
    resolvedStorageRoot = root;
    _startupLog(
      'storage-root-resolve-complete '
      'durationMs=${storageRootClock.elapsedMilliseconds}',
    );
    final durableStateClock = Stopwatch()..start();
    _startupLog('durable-state-check-start');
    // Start the cheap state probe while preferences are being attached. On a
    // warm install this avoids serializing two independent filesystem waits.
    final durableStateFuture = durableZicStateExists(root);
    _startupLog('preferences-attach-start');
    if (preferencesReady != null) {
      await preferencesReady;
    } else {
      final preferencePath = '$root/app_preferences.json';
      try {
        await preferences.attach(
          read: () => readJsonObjectFile(preferencePath),
          write: (values) => writeJsonObjectFile(preferencePath, values),
        );
      } on Object catch (error) {
        debugPrint('app preferences unavailable: $error');
      }
    }
    _startupLog('preferences-attach-complete');
    telemetry.serviceReady('storage-root', startedAtMicros: stageStarted);

    // Finish any deferred chapter-download store move before a service can
    // open the stores, then resolve the effective download directory for this
    // launch. The default-location probe above stays valid; an override only
    // adds one extra cheap file existence check below.
    final configuredChapterDownloadDirectory =
        preferences.chapterDownloadDirectoryOverride ??
        defaultChapterDownloadDirectory(root);
    final chapterMetadataPath = defaultChapterDownloadMetadataPath(root);
    final chapterMetadataPreexisting = await chapterDownloadMetadataExists(root);
    late final String chapterDownloadDirectory;
    var chapterDownloadMoveSettled = true;
    try {
      chapterDownloadDirectory = await settleChapterDownloadDirectory(
        storageRoot: root,
        configuredOverride: preferences.chapterDownloadDirectoryOverride,
        pendingMoveFrom: preferences.chapterDownloadDirectoryPendingMoveFrom,
        metadataDbPath: chapterMetadataPreexisting ? chapterMetadataPath : null,
      );
    } on Object catch (error) {
      // Keep the intent marker when recovery could not finish. The target is
      // still usable for startup, while the next launch gets another chance
      // to complete the source-to-target move.
      chapterDownloadMoveSettled = false;
      final pendingSource =
          preferences.chapterDownloadDirectoryPendingMoveFrom;
      // A preflight failure leaves the source store authoritative. Reopen it
      // when its index is still present; otherwise the destination already
      // owns the moved index and is the only usable recovery side.
      final sourceStillOwnsBytes = pendingSource != null &&
          chapterDownloadStoreHasContent(pendingSource);
      final sourceHasLegacyIndex = pendingSource != null &&
          await chapterDownloadIndexExists(pendingSource);
      chapterDownloadDirectory = sourceStillOwnsBytes || sourceHasLegacyIndex
          ? pendingSource
          : configuredChapterDownloadDirectory;
      debugPrint(
        'chapter-download move recovery failed: $error; '
        'using $chapterDownloadDirectory while retaining retry marker',
      );
    }
    if (chapterDownloadMoveSettled) {
      preferences.setChapterDownloadDirectoryPendingMoveFrom(null);
    }
    final legacyChapterMetadataPath = legacyChapterDownloadMetadataPath(
      storageRoot: root,
      downloadDirectory: chapterDownloadDirectory,
    );
    final metadataMigrated = await migrateLegacyChapterDownloadMetadata(
      legacyDbPath: legacyChapterMetadataPath,
      metadataDbPath: chapterMetadataPath,
    );
    if (metadataMigrated) {
      _startupLog(
        'chapter-download-metadata-migrated '
        'from=$legacyChapterMetadataPath to=$chapterMetadataPath',
      );
    }
    _startupLog(
      'chapter-download-directory-resolved path=$chapterDownloadDirectory '
      'metadata=$chapterMetadataPath',
    );

    // A fresh install has no library, download index, or queue state. Opening
    // both SQLite stores here would create their WAL files and run their first
    // schema transactions solely because Home was shown. Keep the Home
    // projection in memory until an actual durable state exists.
    final hasDurableState = await durableStateFuture ||
        await chapterDownloadMetadataExists(root);
    _startupLog(
      'durable-state-check-complete '
      'durationMs=${durableStateClock.elapsedMilliseconds} '
      'exists=$hasDurableState',
    );
    if (!hasDurableState && !forceDurable) {
      _startupLog('durable-state-absent');
      return _AppServices(storageRoot: root);
    }

    stageStarted = telemetry.nowMicros();
    _startupLog('library-store-open-start');
    final bootstrap = bootstrapLibrary;
    if (bootstrap is LazyImportedLibraryStore) {
      libraryStore = await bootstrap.ensureDurable();
      ownsLibraryStore = false;
    } else {
      libraryStore = await openImportedLibraryStore(root);
    }
    _startupLog(
      'library-store-open-complete '
      'sharedBootstrap=${bootstrap is LazyImportedLibraryStore}',
    );
    telemetry.serviceReady('library-store', startedAtMicros: stageStarted);
    stageStarted = telemetry.nowMicros();
    _startupLog('download-composition-open-start');
    final safOverride = chapterDownloadSafTreeUri(chapterDownloadDirectory);
    defaultDownloadResourceCoordinator.speculativeEncodedReadBudget
        .updateLimitBytes(
      preferences.readerPrefetchReadBudgetMiB * 1024 * 1024,
    );
    downloadComposition = await PersistentDownloadComposition.open(
      root,
      directory: safOverride == null ? chapterDownloadDirectory : null,
      indexPath: chapterMetadataPath,
      layoutResolver: sourceDownloadLayoutResolver(preferences),
      userAgentProvider: () => preferences.networkUserAgent,
      transferNet: defaultDownloadResourceCoordinator.networkLane,
      localReadScheduler: defaultDownloadResourceCoordinator.localReadScheduler,
      storageWriteScheduler: defaultDownloadResourceCoordinator.storageWriteScheduler,
      speculativeEncodedReadBudget:
          defaultDownloadResourceCoordinator.speculativeEncodedReadBudget,
      safTreeIo: safOverride == null
          ? null
          : _SafTreeIoAdapter(SafStore(treeUri: safOverride)),
      safTreeUri: safOverride,
      presentationFileLeaseFactory:
          const _AndroidArtifactPresentationFileLeaseFactory(),
      traceSink: debugTrace,
    );
    _startupLog('download-composition-open-complete');
    chapterDownloads = downloadComposition.chapterDownloads;
    telemetry.serviceReady('chapter-downloads', startedAtMicros: stageStarted);
    stageStarted = telemetry.nowMicros();
    cacheCoordinator = createAppResourceCache(
      storageRoot: root,
      responses: responseCache,
      artifacts: downloadComposition.artifactStore,
      onPersistenceError: (error, stackTrace) {
        debugPrint('durable response cache failed: $error');
      },
    );
    cacheCoordinator.updateMaintenancePolicy(
      ResourceCacheMaintenancePolicy.forArtifactLimitBytes(
        preferences.cacheLimitMb * 1024 * 1024,
      ),
    );
    telemetry.serviceReady('resource-cache', startedAtMicros: stageStarted);
    // The queue starts with its conservative in-memory environment. Attaching
    // RuntimeBridge and receiving the real network/power signal is deferred
    // until after this core service set has produced a visible Home frame.
    final platformEnvironment = PlatformWholeComicQueueEnvironment();
    stageStarted = telemetry.nowMicros();
    wholeComicDownloads = createPersistentWholeComicDownloadQueue(
      path: '$root/whole_comic_queue.json',
      downloads: chapterDownloads,
      environment: platformEnvironment,
      ownsEnvironment: true,
      storageRootId: downloadComposition.artifactStore.storageRootId,
    );
    telemetry.serviceReady('whole-comic-queue', startedAtMicros: stageStarted);
    final services = _AppServices(
      libraryStore: libraryStore,
      ownsLibraryStore: ownsLibraryStore,
      chapterDownloads: chapterDownloads,
      downloadComposition: downloadComposition,
      wholeComicDownloads: wholeComicDownloads,
      cacheCoordinator: cacheCoordinator,
      platformEnvironment: platformEnvironment,
      storageRoot: root,
      storageRootAccessAliasProof: safOverride == null
          ? null
          : _probeStorageRootAccessAlias(safOverride),
    );
    _persistStorageRootAccessAliasProof(services);
    telemetry.servicesReady(startedAtMicros: openedAt);
    _startupLog('durable-services-ready');
    return services;
  } on Object catch (error) {
    // Persist the full failure into the trace file so device-side "downloads
    // finish but nothing lands on disk" reports can be diagnosed from
    // .log/log.txt alone: a failed durable open silently falls back to the
    // memory-backed services below.
    telemetry.sink.record(
      TraceEvent(
        monotonicMicros: telemetry.nowMicros(),
        sessionId: 'home-startup',
        kind: TraceEventKind.taskFailed,
        identityHash: 'home-startup\u0000services-open-failed',
        payload: <String, Object?>{
          'stage': 'durable-services-open',
          'error': '$error',
        },
      ),
    );
    _startupLog('services-open-failed $error');
    debugPrint('durable application storage unavailable: $error');
    await wholeComicDownloads?.close();
    await cacheCoordinator?.close();
    if (downloadComposition != null) {
      await downloadComposition.close();
    } else {
      await chapterDownloads?.close();
    }
    if (ownsLibraryStore) {
      await libraryStore?.close();
    }
    // External source management is independent from the core library and
    // download stores. If one of those stores cannot open (for example while
    // recovering a cross-version schema), keep the resolved root so the
    // Mihon/Venera host can still attach and expose its management pages.
    return _AppServices(storageRoot: resolvedStorageRoot);
  }
}

Future<void> _attachExternalPlugins(
  HomeStartupTelemetry telemetry,
  _AppServices services,
  String root,
  String Function() userAgentProvider,
  int stageStartedMicros, {
  bool force = false,
}) async {
  try {
    if (!force && !await ExternalPluginController.hasDurableManifest(root)) {
      _startupLog('external-plugin-host-skipped-no-manifest');
      return;
    }
    _startupLog('external-plugin-host-open-start');
    await attachAndroidPlugin('plugin_host_bridge');
    final controller = await ExternalPluginController.openDeferred(
      root,
      userAgentProvider: userAgentProvider,
      // Enumerating every installed Android package is a source-management
      // operation, not a Home startup dependency. The repository screen
      // explicitly refreshes device extensions when the user opens it.
      discoverDeviceMihonExtensions: false,
      // Opening the durable manifest must not wake every installed runtime.
      // Home/Reader exact-source misses activate only their owning plugin; the
      // source-management page still requests the complete projection.
      deferRuntimeActivation: true,
    );
    final accepted =
        await services._acceptExternalPluginController(controller);
    if (accepted) {
      telemetry.serviceReady(
        'external-plugin-host',
        startedAtMicros: stageStartedMicros,
      );
      _startupLog('external-plugin-host-open-complete');
    }
  } on Object catch (error) {
    debugPrint('external plugin runtime unavailable: $error');
  }
}

final class App extends StatefulWidget {
  const App({
    this.useLightStartupTheme = false,
    this.picker = defaultWebpPicker,
    this.folderPicker = defaultImageFolderPicker,
    this.folderRefresher = defaultImageFolderRefresher,
    this.libraryStore,
    this.homeProjectionSnapshotStore,
    this.persistHomeProjectionSnapshot = true,
    this.chapterDownloads,
    this.downloadComposition,
    this.wholeComicDownloads,
    this.comicSources,
    this.cacheCoordinator,
    this.externalPlugins,
    this.externalPluginLoader,
    this.platformEnvironmentLoader,
    this.persistMissingPreferences = true,
    this.networkBridge = const AndroidNetworkBridge(),
    this.startupTelemetry,
    this.serviceHandoff,
    this.homeKey,
    this.preferences,
    this.debugTrace,
    this.storageRoot,
    super.key,
  }) : assert(
          wholeComicDownloads == null || chapterDownloads != null,
          'a supplied whole-comic queue must share the supplied chapter service',
        );

  final bool useLightStartupTheme;
  final WebpPicker picker;
  final ImageFolderPicker folderPicker;
  final ImageFolderRefresher folderRefresher;
  final ImportedLibraryStore? libraryStore;
  final HomeProjectionSnapshotStore? homeProjectionSnapshotStore;
  final bool persistHomeProjectionSnapshot;
  final ChapterDownloadService? chapterDownloads;
  final ChapterDownloadTransferRuntimeProvider? downloadComposition;
  final WholeComicDownloadQueue? wholeComicDownloads;
  final List<BrowsableComicSource>? comicSources;
  final ResourceCacheCoordinator? cacheCoordinator;
  final ExternalPluginController? externalPlugins;
  final Future<ExternalPluginController?> Function()? externalPluginLoader;
  final Future<void> Function()? platformEnvironmentLoader;
  final bool persistMissingPreferences;
  final AndroidNetworkBridge networkBridge;
  final AppPreferencesController? preferences;
  final DebugTraceLog? debugTrace;
  final String? storageRoot;
  final HomeStartupTelemetry? startupTelemetry;
  final HomeServiceHandoff? serviceHandoff;
  final Key? homeKey;

  @override
  State<App> createState() => _AppState();
}

final class _AppState extends State<App> {
  late final AppPreferencesController _preferences =
      widget.preferences ?? AppPreferencesController();
  late final DebugTraceLog _debugTrace =
      widget.debugTrace ?? DebugTraceLog();

  @override
  void initState() {
    super.initState();
    _preferences.addListener(_syncTrace);
    _syncTrace();
  }

  void _syncTrace() {
    _debugTrace.enabled =
        _preferences.debugModeEnabled && _preferences.debugTraceEnabled;
  }

  @override
  void dispose() {
    _preferences.removeListener(_syncTrace);
    if (widget.preferences == null) _preferences.dispose();
    if (widget.debugTrace == null) _debugTrace.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _preferences.themeChanges,
      builder: (context, _) => MaterialApp(
        title: 'zic',
        debugShowCheckedModeBanner: false,
        theme: _zicTheme(
          ColorScheme.fromSeed(seedColor: Colors.indigo),
        ),
        darkTheme: _zicTheme(
          _darkColorScheme(amoled: _preferences.amoledDarkTheme),
          amoled: _preferences.amoledDarkTheme,
        ),
        themeMode: _preferences.themeMode,
        home: _RootBackExitGuard(
          child: DemoHome(
            key: widget.homeKey,
            picker: widget.picker,
            folderPicker: widget.folderPicker,
            folderRefresher: widget.folderRefresher,
            libraryStore: widget.libraryStore,
            homeProjectionSnapshotStore: widget.homeProjectionSnapshotStore,
            persistHomeProjectionSnapshot: widget.persistHomeProjectionSnapshot,
            chapterDownloads: widget.chapterDownloads,
            downloadComposition: widget.downloadComposition,
            wholeComicDownloads: widget.wholeComicDownloads,
            comicSources: widget.comicSources,
            externalPlugins: widget.externalPlugins,
            platformEnvironmentLoader: widget.platformEnvironmentLoader,
            networkBridge: widget.networkBridge,
            cacheCoordinator: widget.cacheCoordinator,
            serviceHandoff: widget.serviceHandoff,
            persistMissingPreferences: widget.persistMissingPreferences,
            externalPluginLoader: widget.externalPluginLoader,
            startupTelemetry: widget.startupTelemetry,
            preferences: _preferences,
            debugTrace: _debugTrace,
            storageRoot: widget.storageRoot,
          ),
        ),
      ),
    );
  }
}

final class _RootBackExitGuard extends StatefulWidget {
  const _RootBackExitGuard({required this.child});

  final Widget child;

  @override
  State<_RootBackExitGuard> createState() => _RootBackExitGuardState();
}

final class _RootBackExitGuardState extends State<_RootBackExitGuard> {
  static const Duration _confirmWindow = Duration(seconds: 2);
  bool _exitArmed = false;
  Timer? _disarmTimer;

  void _handlePopInvokedWithResult(bool didPop, Object? result) {
    if (didPop) return;
    if (_exitArmed) {
      _disarm();
      unawaited(_moveToBackground());
      return;
    }
    _exitArmed = true;
    _disarmTimer?.cancel();
    _disarmTimer = Timer(_confirmWindow, () {
      _exitArmed = false;
      _disarmTimer = null;
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('再按一次返回到后台'),
          duration: _confirmWindow,
        ),
      );
  }

  Future<void> _moveToBackground() async {
    final platformHandled = await requestAndroidApplicationBackground();
    if (!platformHandled) {
      await SystemNavigator.pop();
    }
  }

  void _disarm() {
    _exitArmed = false;
    _disarmTimer?.cancel();
    _disarmTimer = null;
  }

  @override
  void dispose() {
    _disarmTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: _handlePopInvokedWithResult,
      child: widget.child,
    );
  }
}

ThemeData _zicTheme(ColorScheme colorScheme, {bool amoled = false}) => ThemeData(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: amoled ? Colors.black : null,
      canvasColor: amoled ? Colors.black : null,
      useMaterial3: true,
      chipTheme: const ChipThemeData(shape: StadiumBorder()),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(shape: const StadiumBorder()),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(shape: const StadiumBorder()),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(shape: const StadiumBorder()),
      ),
    );

ColorScheme _darkColorScheme({required bool amoled}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: Colors.indigo,
    brightness: Brightness.dark,
  );
  if (!amoled) return scheme;
  return scheme.copyWith(
    surface: Colors.black,
    surfaceDim: Colors.black,
    surfaceContainerLowest: Colors.black,
    surfaceContainerLow: const Color(0xff050505),
    surfaceContainer: const Color(0xff0a0a0a),
    surfaceContainerHigh: const Color(0xff101010),
    surfaceContainerHighest: const Color(0xff151515),
  );
}

Widget createApp({
  dynamic picker,
  dynamic folderPicker,
  dynamic folderRefresher,
  dynamic libraryStore,
  dynamic homeProjectionSnapshotStore,
  bool persistHomeProjectionSnapshot = true,
  dynamic chapterDownloads,
  dynamic downloadComposition,
  dynamic wholeComicDownloads,
  dynamic comicSources,
  dynamic cacheCoordinator,
  dynamic externalPlugins,
  dynamic externalPluginLoader,
  dynamic platformEnvironmentLoader,
  bool persistMissingPreferences = true,
  dynamic networkBridge,
  dynamic startupTelemetry,
  Key? homeKey,
  dynamic preferences,
  dynamic debugTrace,
  String? storageRoot,
}) {
  return App(
    picker: picker is WebpPicker ? picker : defaultWebpPicker,
    folderPicker: folderPicker is ImageFolderPicker
        ? folderPicker
        : defaultImageFolderPicker,
    folderRefresher: folderRefresher is ImageFolderRefresher
        ? folderRefresher
        : defaultImageFolderRefresher,
    libraryStore: libraryStore as ImportedLibraryStore?,
    homeProjectionSnapshotStore:
        homeProjectionSnapshotStore as HomeProjectionSnapshotStore?,
    persistHomeProjectionSnapshot: persistHomeProjectionSnapshot,
    chapterDownloads: chapterDownloads as ChapterDownloadService?,
    downloadComposition:
        downloadComposition as ChapterDownloadTransferRuntimeProvider?,
    wholeComicDownloads: wholeComicDownloads as WholeComicDownloadQueue?,
    comicSources: comicSources == null
        ? null
        : List<BrowsableComicSource>.from(
            comicSources as Iterable<BrowsableComicSource>,
          ),
    cacheCoordinator: cacheCoordinator as ResourceCacheCoordinator?,
    externalPlugins: externalPlugins as ExternalPluginController?,
    externalPluginLoader: externalPluginLoader == null
        ? null
        : externalPluginLoader
            as Future<ExternalPluginController?> Function(),
    platformEnvironmentLoader: platformEnvironmentLoader == null
        ? null
        : platformEnvironmentLoader as Future<void> Function(),
    persistMissingPreferences: persistMissingPreferences,
    networkBridge: networkBridge is AndroidNetworkBridge
        ? networkBridge
        : const AndroidNetworkBridge(),
    startupTelemetry: startupTelemetry as HomeStartupTelemetry?,
    homeKey: homeKey,
    preferences: preferences as AppPreferencesController?,
    debugTrace: debugTrace as DebugTraceLog?,
    storageRoot: storageRoot,
  );
}

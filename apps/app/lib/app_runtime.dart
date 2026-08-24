import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:downloads/downloads.dart';
import 'package:downloads_bridge/downloads_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:network_bridge/network_bridge.dart';
import 'package:plugin_host_bridge/plugin_host_bridge.dart';
import 'package:plugin_host_bridge/runtime_service_entrypoint.dart'
    as plugin_runtime_service;
import 'package:resource_cache/resource_cache.dart';
import 'package:storage_bridge/storage_bridge.dart';
import 'package:telemetry/telemetry.dart';

import 'app_preferences.dart';
import 'debug_trace.dart';
import 'demo_home.dart';
import 'home_library_session.dart';
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

final Stopwatch _startupClock = Stopwatch()..start();

void _startupLog(String message) => debugPrint(
      '[zic-startup] elapsedMs=${_startupClock.elapsedMilliseconds} $message',
    );

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
  bool _homeMounted = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    _bootstrapLibrary = createLazyImportedLibraryStore(
      storageRoot: () => _storageRoot,
    );
    _serviceHandoff = HomeServiceHandoff()
      ..setBootstrapLibrary(_bootstrapLibrary)
      ..setBootstrapCache(_bootstrapCache);
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
    // A post-frame callback is the visibility boundary. Do not wait for the
    // engine raster Future here: on some Flutter/Android combinations that
    // Future never completes although the bootstrap frame is already shown.
    await Future<void>.delayed(Duration.zero);
    if (_disposed) return;
    _startupLog('runtime-bootstrap-frame-rasterized');
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

  Future<void> _openDurableServices() async {
    if (_disposed) return;
    _startupLog('services-open-start');
    _startupTelemetry.servicesOpenStarted();
    final services = await _openServices(
      _startupTelemetry,
      _preferences,
      storageRoot: _storageRoot,
      preferencesReady: _preferencesReady,
      responseCache: _serviceHandoff.cacheCoordinator?.responses,
    );
    if (_disposed) {
      if (services.hasCoreServices) {
        unawaited(services.close());
      }
      return;
    }
    if (!services.hasCoreServices) {
      // Empty installs deliberately remain memory-backed. In particular, do
      // not create SQLite/WAL files merely because Home was opened. The first
      // explicit durable operation is responsible for crossing that boundary.
      _startupLog('services-open-skipped-empty-state');
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
    _services = services;
    _serviceHandoff.updateServices(
      libraryStore: services.libraryStore,
      chapterDownloads: services.chapterDownloads,
      downloadComposition: services.downloadComposition,
      wholeComicDownloads: services.wholeComicDownloads,
      cacheCoordinator: services.cacheCoordinator,
      externalPlugins: services.externalPlugins,
      externalPluginLoader: () => _ensureExternalPlugins(services),
      platformEnvironmentLoader: services.ensurePlatformEnvironment,
      storageRoot: services.storageRoot,
      persistHomeProjectionSnapshot: true,
    );
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

  void _syncDebugTrace() {
    _debugTrace.enabled = _preferences.debugTraceEnabled;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_services?.checkpointTransferPartials());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _servicesStartupTimer?.cancel();
    _servicesStartupTimer = null;
    WidgetsBinding.instance.removeObserver(this);
    _preferences.removeListener(_syncDebugTrace);
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
    this.chapterDownloads,
    this.downloadComposition,
    this.wholeComicDownloads,
    this.cacheCoordinator,
    this.platformEnvironment,
    this.storageRoot,
  });

  final ImportedLibraryStore? libraryStore;
  final ManagedChapterDownloadService? chapterDownloads;
  final PersistentDownloadComposition? downloadComposition;
  final WholeComicDownloadQueue? wholeComicDownloads;
  final ResourceCacheCoordinator? cacheCoordinator;
  final PlatformWholeComicQueueEnvironment? platformEnvironment;
  final String? storageRoot;

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
  Future<ExternalPluginController?>? _externalPluginOpening;
  Future<void>? _platformEnvironmentOpening;
  bool _closed = false;
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

  Future<ExternalPluginController?> ensureExternalPlugins({
    required HomeStartupTelemetry telemetry,
    required AppPreferencesController preferences,
  }) {
    final current = externalPlugins;
    if (current != null) {
      return Future<ExternalPluginController?>.value(current);
    }
    final opening = _externalPluginOpening;
    if (opening != null) {
      return opening;
    }
    final root = storageRoot;
    if (root == null || _closed) {
      return Future<ExternalPluginController?>.value();
    }
    final background = externalPluginsReady;
    late final Future<ExternalPluginController?> forcedOpening;
    forcedOpening = background.then<ExternalPluginController?>((_) async {
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
      return externalPlugins;
    });
    _externalPluginOpening = forcedOpening;
    externalPluginsReady = forcedOpening.then<void>((_) {});
    return forcedOpening;
  }

  Future<void> checkpointTransferPartials() {
    final composition = downloadComposition;
    if (composition == null || _closed) return Future<void>.value();
    final running = _partialCheckpoint;
    if (running != null) return running;
    late final Future<void> checkpoint;
    checkpoint = composition.transferRuntime
        .checkpointPartials(reason: 'app-lifecycle-checkpoint')
        .whenComplete(() {
      if (identical(_partialCheckpoint, checkpoint)) {
        _partialCheckpoint = null;
      }
    });
    _partialCheckpoint = checkpoint;
    return checkpoint;
  }

  Future<void> close() async {
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
      await defaultLocalMediaPipelineFactory.disposeRetainedSessions();
    } on Object catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    // The deferred plugin open may still be in flight; settle it before the
    // close pass so a late controller cannot leak after teardown.
    try {
      await externalPluginsReady.timeout(const Duration(minutes: 1));
    } on Object catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    try {
      await _platformEnvironmentOpening?.timeout(const Duration(minutes: 1));
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
      if (libraryStore != null) libraryStore!.close,
    ]) {
      try {
        await close();
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

Future<_AppServices> _openServices(
  HomeStartupTelemetry telemetry,
  AppPreferencesController preferences, {
  Future<String>? storageRoot,
  Future<void>? preferencesReady,
  ResourceCacheManager? responseCache,
}) async {
  ImportedLibraryStore? libraryStore;
  ManagedChapterDownloadService? chapterDownloads;
  PersistentDownloadComposition? downloadComposition;
  WholeComicDownloadQueue? wholeComicDownloads;
  ResourceCacheCoordinator? cacheCoordinator;
  try {
    final openedAt = telemetry.nowMicros();
    var stageStarted = telemetry.nowMicros();
    final storageRootClock = Stopwatch()..start();
    _startupLog('storage-root-resolve-start');
    final root = await (storageRoot ??
        getDefaultZicStorageRoot(
          applicationSupportPath: getStartupApplicationSupportPath,
        ));
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

    // A fresh install has no library, download index, or queue state. Opening
    // both SQLite stores here would create their WAL files and run their first
    // schema transactions solely because Home was shown. Keep the Home
    // projection in memory until an actual durable state exists.
    final hasDurableState = await durableStateFuture;
    _startupLog(
      'durable-state-check-complete '
      'durationMs=${durableStateClock.elapsedMilliseconds} '
      'exists=$hasDurableState',
    );
    if (!hasDurableState) {
      _startupLog('durable-state-absent');
      return _AppServices(storageRoot: root);
    }

    stageStarted = telemetry.nowMicros();
    _startupLog('library-store-open-start');
    libraryStore = await openImportedLibraryStore(root);
    _startupLog('library-store-open-complete');
    telemetry.serviceReady('library-store', startedAtMicros: stageStarted);
    stageStarted = telemetry.nowMicros();
    _startupLog('download-composition-open-start');
    downloadComposition = await PersistentDownloadComposition.open(
      root,
      userAgentProvider: () => preferences.networkUserAgent,
      transferNet: defaultLocalMediaPipelineFactory.pageDownloadLane,
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
    );
    telemetry.serviceReady('whole-comic-queue', startedAtMicros: stageStarted);
    final services = _AppServices(
      libraryStore: libraryStore,
      chapterDownloads: chapterDownloads,
      downloadComposition: downloadComposition,
      wholeComicDownloads: wholeComicDownloads,
      cacheCoordinator: cacheCoordinator,
      platformEnvironment: platformEnvironment,
      storageRoot: root,
    );
    telemetry.servicesReady(startedAtMicros: openedAt);
    _startupLog('durable-services-ready');
    return services;
  } on Object catch (error) {
    _startupLog('services-open-failed errorType=${error.runtimeType}');
    debugPrint('durable application storage unavailable: $error');
    await wholeComicDownloads?.close();
    await cacheCoordinator?.close();
    if (downloadComposition != null) {
      await downloadComposition.close();
    } else {
      await chapterDownloads?.close();
    }
    await libraryStore?.close();
    return _AppServices();
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
    );
    if (!services._closed && services.externalPlugins == null) {
      services.externalPlugins = controller;
      telemetry.serviceReady(
        'external-plugin-host',
        startedAtMicros: stageStartedMicros,
      );
      _startupLog('external-plugin-host-open-complete');
      return;
    }
    // The app tore down while the host was opening; release it immediately.
    await controller.close();
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
    _debugTrace.enabled = _preferences.debugTraceEnabled;
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
      animation: _preferences,
      builder: (context, _) => MaterialApp(
        title: 'zic',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: _darkColorScheme(
            amoled: _preferences.amoledDarkTheme,
          ),
          scaffoldBackgroundColor: _preferences.amoledDarkTheme
              ? Colors.black
              : null,
          canvasColor:
              _preferences.amoledDarkTheme ? Colors.black : null,
          useMaterial3: true,
        ),
        themeMode: _preferences.themeMode,
        home: DemoHome(
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
    );
  }
}

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

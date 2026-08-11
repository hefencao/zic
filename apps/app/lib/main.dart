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
import 'webp_demo.dart';

@pragma('vm:entry-point')
Future<void> zicExternalPluginRuntimeServiceMain() =>
    plugin_runtime_service.zicExternalPluginRuntimeServiceMain();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _BootstrapApp());
  unawaited(_prewarmMediaInBackground());
}

Future<void> _prewarmMediaInBackground() async {
  unawaited(prewarmPlatformSourceResourceTransport().catchError((Object error) {
    debugPrint('source media transport prewarm unavailable: $error');
  }));
  try {
    await prewarmDefaultLocalMediaPipeline();
  } on Object catch (error) {
    debugPrint('native media prewarm unavailable: $error');
  }
}

final class _BootstrapApp extends StatefulWidget {
  const _BootstrapApp();

  @override
  State<_BootstrapApp> createState() => _BootstrapAppState();
}

final class _BootstrapAppState extends State<_BootstrapApp> {
  late final AppPreferencesController _preferences;
  late final DebugTraceLog _debugTrace;
  late final HomeStartupTelemetry _startupTelemetry;
  _AppServices? _services;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _preferences = AppPreferencesController();
    _debugTrace = DebugTraceLog();
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
    _startupTelemetry.servicesOpenStarted();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) {
        _startupTelemetry.bootstrapPresented();
      }
    });
    unawaited(
      _openServices(_startupTelemetry, _preferences).then<void>((services) {
        if (_disposed) {
          unawaited(services.close());
        } else {
          setState(() => _services = services);
        }
      }),
    );
  }

  void _syncDebugTrace() {
    _debugTrace.enabled = _preferences.debugTraceEnabled;
  }

  @override
  void dispose() {
    _disposed = true;
    _preferences.removeListener(_syncDebugTrace);
    final services = _services;
    if (services != null) {
      unawaited(services.close());
    }
    unawaited(_preferences.flush());
    _preferences.dispose();
    _debugTrace.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final services = _services;
    return App(
      homeKey: ValueKey<String>(
        services == null ? 'bootstrap-memory' : 'durable-services',
      ),
      libraryStore: services?.libraryStore,
      chapterDownloads: services?.chapterDownloads,
      downloadComposition: services?.downloadComposition,
      wholeComicDownloads: services?.wholeComicDownloads,
      cacheCoordinator: services?.cacheCoordinator,
      externalPlugins: services?.externalPlugins,
      startupTelemetry: _startupTelemetry,
      preferences: _preferences,
      debugTrace: _debugTrace,
      storageRoot: services?.storageRoot,
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
    this.externalPlugins,
    this.storageRoot,
  });

  final ImportedLibraryStore? libraryStore;
  final ManagedChapterDownloadService? chapterDownloads;
  final PersistentDownloadComposition? downloadComposition;
  final WholeComicDownloadQueue? wholeComicDownloads;
  final ResourceCacheCoordinator? cacheCoordinator;
  final ExternalPluginController? externalPlugins;
  final String? storageRoot;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      await defaultLocalMediaPipelineFactory.disposeRetainedSessions();
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
  AppPreferencesController preferences,
) async {
  ImportedLibraryStore? libraryStore;
  ManagedChapterDownloadService? chapterDownloads;
  PersistentDownloadComposition? downloadComposition;
  WholeComicDownloadQueue? wholeComicDownloads;
  ResourceCacheCoordinator? cacheCoordinator;
  ExternalPluginController? externalPlugins;
  try {
    final openedAt = telemetry.nowMicros();
    var stageStarted = telemetry.nowMicros();
    final root = await getDefaultZicStorageRoot();
    final preferencePath = '$root/app_preferences.json';
    try {
      await preferences.attach(
        read: () => readJsonObjectFile(preferencePath),
        write: (values) => writeJsonObjectFile(preferencePath, values),
      );
    } on Object catch (error) {
      debugPrint('app preferences unavailable: $error');
    }
    telemetry.serviceReady('storage-root', startedAtMicros: stageStarted);
    stageStarted = telemetry.nowMicros();
    libraryStore = await openImportedLibraryStore(root);
    telemetry.serviceReady('library-store', startedAtMicros: stageStarted);
    stageStarted = telemetry.nowMicros();
    downloadComposition = await PersistentDownloadComposition.open(
      root,
      userAgentProvider: () => preferences.networkUserAgent,
      transferNet: defaultLocalMediaPipelineFactory.pageDownloadLane,
    );
    chapterDownloads = downloadComposition.chapterDownloads;
    telemetry.serviceReady('chapter-downloads', startedAtMicros: stageStarted);
    stageStarted = telemetry.nowMicros();
    cacheCoordinator = createAppResourceCache(
      storageRoot: root,
      artifacts: downloadComposition.artifactStore,
      onPersistenceError: (error, stackTrace) {
        debugPrint('durable response cache failed: $error');
      },
    );
    telemetry.serviceReady('resource-cache', startedAtMicros: stageStarted);
    WholeComicQueueEnvironmentSource queueEnvironment =
        const StaticWholeComicQueueEnvironment();
    PlatformWholeComicQueueEnvironment? platformEnvironment;
    try {
      final candidate = PlatformWholeComicQueueEnvironment();
      platformEnvironment = candidate;
      await candidate.initialize();
      queueEnvironment = candidate;
    } on Object catch (error) {
      if (platformEnvironment != null) {
        await platformEnvironment.close();
      }
      debugPrint('runtime download policy signals unavailable: $error');
    }
    stageStarted = telemetry.nowMicros();
    wholeComicDownloads = createPersistentWholeComicDownloadQueue(
      path: '$root/whole_comic_queue.json',
      downloads: chapterDownloads,
      environment: queueEnvironment,
      ownsEnvironment: platformEnvironment != null,
    );
    telemetry.serviceReady('whole-comic-queue', startedAtMicros: stageStarted);
    stageStarted = telemetry.nowMicros();
    try {
      externalPlugins = await ExternalPluginController.openDeferred(
        root,
        userAgentProvider: () => preferences.networkUserAgent,
      );
      telemetry.serviceReady(
        'external-plugin-host',
        startedAtMicros: stageStarted,
      );
    } on Object catch (error) {
      debugPrint('external plugin runtime unavailable: $error');
    }
    telemetry.servicesReady(startedAtMicros: openedAt);
    return _AppServices(
      libraryStore: libraryStore,
      chapterDownloads: chapterDownloads,
      downloadComposition: downloadComposition,
      wholeComicDownloads: wholeComicDownloads,
      cacheCoordinator: cacheCoordinator,
      externalPlugins: externalPlugins,
      storageRoot: root,
    );
  } on Object catch (error) {
    debugPrint('durable application storage unavailable: $error');
    await wholeComicDownloads?.close();
    await externalPlugins?.close();
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

final class App extends StatefulWidget {
  const App({
    this.picker = defaultWebpPicker,
    this.folderPicker = defaultImageFolderPicker,
    this.folderRefresher = defaultImageFolderRefresher,
    this.libraryStore,
    this.chapterDownloads,
    this.downloadComposition,
    this.wholeComicDownloads,
    this.comicSources,
    this.cacheCoordinator,
    this.externalPlugins,
    this.networkBridge = const AndroidNetworkBridge(),
    this.startupTelemetry,
    this.homeKey,
    this.preferences,
    this.debugTrace,
    this.storageRoot,
    super.key,
  }) : assert(
          wholeComicDownloads == null || chapterDownloads != null,
          'a supplied whole-comic queue must share the supplied chapter service',
        );

  final WebpPicker picker;
  final ImageFolderPicker folderPicker;
  final ImageFolderRefresher folderRefresher;
  final ImportedLibraryStore? libraryStore;
  final ChapterDownloadService? chapterDownloads;
  final ChapterDownloadTransferRuntimeProvider? downloadComposition;
  final WholeComicDownloadQueue? wholeComicDownloads;
  final List<BrowsableComicSource>? comicSources;
  final ResourceCacheCoordinator? cacheCoordinator;
  final ExternalPluginController? externalPlugins;
  final AndroidNetworkBridge networkBridge;
  final AppPreferencesController? preferences;
  final DebugTraceLog? debugTrace;
  final String? storageRoot;
  final HomeStartupTelemetry? startupTelemetry;
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
        key: ValueKey<String>(widget.storageRoot ?? 'bootstrap-memory'),
        title: 'zic',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.indigo,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        themeMode: _preferences.themeMode,
        home: DemoHome(
          key: widget.homeKey,
          picker: widget.picker,
          folderPicker: widget.folderPicker,
          folderRefresher: widget.folderRefresher,
          libraryStore: widget.libraryStore,
          chapterDownloads: widget.chapterDownloads,
          downloadComposition: widget.downloadComposition,
          wholeComicDownloads: widget.wholeComicDownloads,
          comicSources: widget.comicSources,
          externalPlugins: widget.externalPlugins,
          networkBridge: widget.networkBridge,
          cacheCoordinator: widget.cacheCoordinator,
          startupTelemetry: widget.startupTelemetry,
          preferences: _preferences,
          debugTrace: _debugTrace,
          storageRoot: widget.storageRoot,
        ),
      ),
    );
  }
}

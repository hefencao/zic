import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:downloads/downloads.dart';
import 'package:downloads_bridge/downloads_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:storage_bridge/storage_bridge.dart';
import 'package:telemetry/telemetry.dart';

import 'demo_home.dart';
import 'webp_demo.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _BootstrapApp());
}

final class _BootstrapApp extends StatefulWidget {
  const _BootstrapApp();

  @override
  State<_BootstrapApp> createState() => _BootstrapAppState();
}

final class _BootstrapAppState extends State<_BootstrapApp> {
  late final HomeStartupTelemetry _startupTelemetry;
  late final Future<_AppServices> _servicesFuture;
  _AppServices? _services;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _startupTelemetry = HomeStartupTelemetry(
      clock: SystemClock(),
      sink: kDebugMode
          ? CallbackTraceSink((event) => debugPrint(event.toJsonLine()))
          : const NoopTraceSink(),
    );
    _startupTelemetry.servicesOpenStarted();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) {
        _startupTelemetry.bootstrapPresented();
      }
    });
    _servicesFuture = _openServices(_startupTelemetry).then((services) {
      if (_disposed) {
        unawaited(services.close());
      } else {
        _services = services;
      }
      return services;
    });
  }

  @override
  void dispose() {
    _disposed = true;
    final services = _services;
    if (services != null) {
      unawaited(services.close());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_AppServices>(
      future: _servicesFuture,
      builder: (context, snapshot) {
        final services = snapshot.data;
        if (services == null) {
          return const _StartupApp();
        }
        return App(
          libraryStore: services.libraryStore,
          chapterDownloads: services.chapterDownloads,
          wholeComicDownloads: services.wholeComicDownloads,
          cacheCoordinator: services.cacheCoordinator,
          startupTelemetry: _startupTelemetry,
        );
      },
    );
  }
}

final class _StartupApp extends StatelessWidget {
  const _StartupApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'zic',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const Scaffold(
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.auto_stories_outlined, size: 52),
                SizedBox(height: 18),
                Text('正在恢复书架'),
                SizedBox(height: 14),
                SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _AppServices {
  _AppServices({
    this.libraryStore,
    this.chapterDownloads,
    this.wholeComicDownloads,
    this.cacheCoordinator,
  });

  final ImportedLibraryStore? libraryStore;
  final ManagedChapterDownloadService? chapterDownloads;
  final WholeComicDownloadQueue? wholeComicDownloads;
  final ResourceCacheCoordinator? cacheCoordinator;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final close in <Future<void> Function()>[
      if (wholeComicDownloads != null) wholeComicDownloads!.close,
      if (cacheCoordinator != null) cacheCoordinator!.close,
      if (chapterDownloads != null) chapterDownloads!.close,
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

Future<_AppServices> _openServices(HomeStartupTelemetry telemetry) async {
  ImportedLibraryStore? libraryStore;
  ManagedChapterDownloadService? chapterDownloads;
  WholeComicDownloadQueue? wholeComicDownloads;
  ResourceCacheCoordinator? cacheCoordinator;
  try {
    final openedAt = telemetry.nowMicros();
    var stageStarted = telemetry.nowMicros();
    final root = await getDefaultZicStorageRoot();
    telemetry.serviceReady('storage-root', startedAtMicros: stageStarted);
    stageStarted = telemetry.nowMicros();
    libraryStore = await openImportedLibraryStore(root);
    telemetry.serviceReady('library-store', startedAtMicros: stageStarted);
    stageStarted = telemetry.nowMicros();
    chapterDownloads = await PersistentChapterDownloadService.open(root);
    telemetry.serviceReady('chapter-downloads', startedAtMicros: stageStarted);
    stageStarted = telemetry.nowMicros();
    cacheCoordinator = createAppResourceCache(
      storageRoot: root,
      artifacts: chapterDownloads,
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
    wholeComicDownloads = await openPersistentWholeComicDownloadQueue(
      path: '$root/whole_comic_queue.json',
      downloads: chapterDownloads,
      environment: queueEnvironment,
      ownsEnvironment: platformEnvironment != null,
    );
    telemetry.serviceReady('whole-comic-queue', startedAtMicros: stageStarted);
    telemetry.servicesReady(startedAtMicros: openedAt);
    return _AppServices(
      libraryStore: libraryStore,
      chapterDownloads: chapterDownloads,
      wholeComicDownloads: wholeComicDownloads,
      cacheCoordinator: cacheCoordinator,
    );
  } on Object catch (error) {
    debugPrint('durable application storage unavailable: $error');
    await wholeComicDownloads?.close();
    await cacheCoordinator?.close();
    await chapterDownloads?.close();
    await libraryStore?.close();
    return _AppServices();
  }
}

final class App extends StatelessWidget {
  const App({
    this.picker = defaultWebpPicker,
    this.folderPicker = defaultImageFolderPicker,
    this.folderRefresher = defaultImageFolderRefresher,
    this.libraryStore,
    this.chapterDownloads,
    this.wholeComicDownloads,
    this.comicSources,
    this.cacheCoordinator,
    this.startupTelemetry,
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
  final WholeComicDownloadQueue? wholeComicDownloads;
  final List<BrowsableComicSource>? comicSources;
  final ResourceCacheCoordinator? cacheCoordinator;
  final HomeStartupTelemetry? startupTelemetry;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
      themeMode: ThemeMode.dark,
      home: DemoHome(
        picker: picker,
        folderPicker: folderPicker,
        folderRefresher: folderRefresher,
        libraryStore: libraryStore,
        chapterDownloads: chapterDownloads,
        wholeComicDownloads: wholeComicDownloads,
        comicSources: comicSources,
        cacheCoordinator: cacheCoordinator,
        startupTelemetry: startupTelemetry,
      ),
    );
  }
}

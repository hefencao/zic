import 'package:catalog/catalog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:storage_bridge/storage_bridge.dart';
import 'package:resource_cache/resource_cache.dart';

import 'package:downloads/downloads.dart';
import 'package:downloads_bridge/downloads_bridge.dart';
import 'demo_home.dart';
import 'webp_demo.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ImportedLibraryStore? libraryStore;
  ManagedChapterDownloadService? chapterDownloads;
  WholeComicDownloadQueue? wholeComicDownloads;
  ResourceCacheCoordinator? cacheCoordinator;
  try {
    final root = await getDefaultZicStorageRoot();
    libraryStore = await openDefaultImportedLibraryStore();
    chapterDownloads = await PersistentChapterDownloadService.open(root);
    cacheCoordinator = createAppResourceCache(
      storageRoot: root,
      artifacts: chapterDownloads,
      onPersistenceError: (error, stackTrace) {
        debugPrint('durable response cache failed: $error');
      },
    );
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
    wholeComicDownloads = await openPersistentWholeComicDownloadQueue(
      path: '$root/whole_comic_queue.json',
      downloads: chapterDownloads,
      environment: queueEnvironment,
      ownsEnvironment: platformEnvironment != null,
    );
  } on Object catch (error) {
    debugPrint('durable application storage unavailable: $error');
  }
  runApp(
    App(
      libraryStore: libraryStore,
      chapterDownloads: chapterDownloads,
      wholeComicDownloads: wholeComicDownloads,
      cacheCoordinator: cacheCoordinator,
    ),
  );
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
      ),
    );
  }
}

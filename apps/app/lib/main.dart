import 'package:catalog/catalog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:storage_bridge/storage_bridge.dart';

import 'chapter_downloads.dart';
import 'demo_home.dart';
import 'whole_comic_downloads.dart';
import 'webp_demo.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ImportedLibraryStore? libraryStore;
  ChapterDownloadService? chapterDownloads;
  WholeComicDownloadQueue? wholeComicDownloads;
  try {
    final root = await getDefaultZicStorageRoot();
    libraryStore = await openDefaultImportedLibraryStore();
    chapterDownloads = await PersistentChapterDownloadService.open(root);
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
    wholeComicDownloads = await WholeComicDownloadQueue.open(
      path: '$root/whole_comic_queue.json',
      downloads: chapterDownloads,
      environment: queueEnvironment,
    );
  } on Object catch (error) {
    debugPrint('durable application storage unavailable: $error');
  }
  runApp(
    App(
      libraryStore: libraryStore,
      chapterDownloads: chapterDownloads,
      wholeComicDownloads: wholeComicDownloads,
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
      ),
    );
  }
}

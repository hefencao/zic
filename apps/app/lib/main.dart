import 'package:catalog/catalog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:storage_bridge/storage_bridge.dart';

import 'chapter_downloads.dart';
import 'demo_home.dart';
import 'webp_demo.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ImportedLibraryStore? libraryStore;
  ChapterDownloadService? chapterDownloads;
  try {
    final root = await getDefaultZicStorageRoot();
    libraryStore = await openDefaultImportedLibraryStore();
    chapterDownloads = await PersistentChapterDownloadService.open(root);
  } on Object catch (error) {
    debugPrint('durable application storage unavailable: $error');
  }
  runApp(
    App(
      libraryStore: libraryStore,
      chapterDownloads: chapterDownloads,
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
    this.comicSources,
    super.key,
  });

  final WebpPicker picker;
  final ImageFolderPicker folderPicker;
  final ImageFolderRefresher folderRefresher;
  final ImportedLibraryStore? libraryStore;
  final ChapterDownloadService? chapterDownloads;
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
        comicSources: comicSources,
      ),
    );
  }
}

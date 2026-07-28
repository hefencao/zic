import 'package:catalog/catalog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:storage_bridge/storage_bridge.dart';

import 'demo_home.dart';
import 'webp_demo.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ImportedLibraryStore? libraryStore;
  try {
    libraryStore = await openDefaultImportedLibraryStore();
  } on Object catch (error) {
    debugPrint('durable imported library unavailable: $error');
  }
  runApp(App(libraryStore: libraryStore));
}

final class App extends StatelessWidget {
  const App({
    this.picker = defaultWebpPicker,
    this.folderPicker = defaultImageFolderPicker,
    this.folderRefresher = defaultImageFolderRefresher,
    this.libraryStore,
    super.key,
  });

  final WebpPicker picker;
  final ImageFolderPicker folderPicker;
  final ImageFolderRefresher folderRefresher;
  final ImportedLibraryStore? libraryStore;

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
      ),
    );
  }
}

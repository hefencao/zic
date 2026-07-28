import 'package:flutter/material.dart';

import 'demo_home.dart';
import 'webp_demo.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const App());
}

final class App extends StatelessWidget {
  const App({
    this.picker = defaultWebpPicker,
    this.folderPicker = defaultWebpFolderPicker,
    super.key,
  });

  final WebpPicker picker;
  final WebpFolderPicker folderPicker;

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
      home: DemoHome(picker: picker, folderPicker: folderPicker),
    );
  }
}

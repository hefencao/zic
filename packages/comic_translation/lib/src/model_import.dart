import 'dart:convert';
import 'dart:io';

import 'benchmark.dart';
import 'local_model_manager.dart';
import 'models.dart';

/// Imports from a direct directory or a platform-owned read capability (SAF).
/// Only the validated manifest's exact files are materialized and verified.
Future<ComicLocalTranslationModel> importComicTranslationModelDirectory(
  String directory, {
  Stream<List<int>> Function(String name)? readFile,
}) async {
  final manager = ComicLocalTranslationModelManager.instance;
  if (readFile == null) return manager.installFromDirectory(directory);
  final temporary = await Directory.systemTemp.createTemp('zic-translation-model-');
  try {
    Future<void> copy(String name) async {
      final file = File('${temporary.path}/$name');
      final sink = file.openWrite();
      try {
        await sink.addStream(readFile(name));
      } finally {
        await sink.close();
      }
    }
    await copy('manifest.json');
    final model = ComicLocalTranslationModel.fromManifest(
      Map<String, dynamic>.from(jsonDecode(await File('${temporary.path}/manifest.json').readAsString()) as Map),
      temporary.path,
    );
    for (final name in model.files.keys) {
      await copy(name);
    }
    return await manager.installFromDirectory(temporary.path);
  } finally {
    await temporary.delete(recursive: true);
  }
}

/// Owns temporary benchmark input, including exceptional exits.
Future<ComicTranslationBenchmarkResult> benchmarkComicTranslationImage({
  required Future<void> Function(String path) copyImage,
  required String sourceLanguage,
  required String targetLanguage,
  required bool runTranslation,
}) async {
  final temporary = await Directory.systemTemp.createTemp('zic-translation-benchmark-');
  try {
    final image = File('${temporary.path}/input');
    await copyImage(image.path);
    final identity = ComicTranslationPageIdentity(
      imageKey: image.uri.toString(), sourceKey: 'benchmark', comicId: 'benchmark',
      chapterId: 'benchmark', pageIndex: 0, mediaKind: ComicTranslationMediaKind.staticImage,
    );
    return await ComicTranslationBenchmark().run(
      pages: [identity], sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
      runTranslation: runTranslation,
    );
  } finally {
    await temporary.delete(recursive: true);
  }
}

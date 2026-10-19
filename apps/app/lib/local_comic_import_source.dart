import 'package:catalog/catalog.dart';
import 'package:downloads/downloads.dart';
import 'package:path/path.dart' as p;

import 'saf_store.dart';
import 'webp_demo.dart';

/// Resolves only an ordinary image chapter. App downloads and archives retain
/// the copy/import contract; external paths never become owned download paths.
Future<ImportedChapterRecord> linkedLocalComicChapter(
  ExternalDownloadTree tree,
  ExternalDownloadComic comic,
  ExternalDownloadChapter chapter, {
  required void Function() checkCancelled,
}) async {
  if (!comic.canReadDirectly || !comic.chapters.contains(chapter)) {
    throw const FormatException('此格式需要复制到 ZIC');
  }
  checkCancelled();
  final path = checkedExternalPath(chapter.path, allowRoot: true);
  final String directoryId;
  if (tree is DirectoryExternalDownloadTree) {
    directoryId = p.joinAll([tree.root.path, ...path.split('/').where((part) => part.isNotEmpty)]);
  } else if (tree is SafExternalDownloadTree && tree.identity.startsWith('saf://')) {
    final treeUri = tree.identity.substring(6);
    if (path.isEmpty) {
      directoryId = treeUri;
    } else {
      final parent = p.posix.dirname(path);
      final entries = await SafStore(treeUri: treeUri).list(parent == '.' ? '' : parent);
      checkCancelled();
      final matches = entries.where((entry) => entry.isDirectory &&
          entry.name == p.posix.basename(path) && entry.uri != null).toList();
      if (matches.length != 1) throw const FormatException('无法定位原目录，请重新选择并扫描');
      directoryId = matches.single.uri!;
    }
  } else {
    throw const FormatException('此目录不支持直接读取，请复制到 ZIC');
  }
  final folder = await loadImageFolder(directoryId, recursive: false);
  checkCancelled();
  final expectedNames = chapter.pages.map(p.posix.basename).toList();
  final byName = {for (final image in folder.files) image.displayName: image};
  if (expectedNames.any((name) => !byName.containsKey(name))) {
    throw const FormatException('目录内容与预览不同，请重新扫描');
  }
  final cover = byName.values.where((image) =>
      p.posix.basenameWithoutExtension(image.displayName).toLowerCase() == 'cover' &&
      !image.displayName.contains('/'));
  final selectedFolder = PickedImageFolder(
    directoryPath: folder.directoryPath, displayName: comic.title,
    files: [for (final name in expectedNames) byName[name]!,
      ...cover.where((image) => !expectedNames.contains(image.displayName))],
    scannedFiles: folder.scannedFiles, unreadableFiles: folder.unreadableFiles,
  );
  return imageFolderChapterRecord(selectedFolder).copyWith(
    directoryRecursive: false,
    displayName: chapter.title, comicTitle: comic.title,
    comicAuthors: comic.authors, comicTags: comic.tags,
    comicDescription: comic.description,
  );
}

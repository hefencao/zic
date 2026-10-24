part of 'external_download_import.dart';

Future<ExternalDownloadComic> _scanZicComic(ExternalDownloadTree tree,
    String directory, List<ExternalDownloadFile> entries,
    List<String> warnings, void Function() check) async {
  final bytes = await _readExternalBytes(tree,
    externalChildPath(directory, comicManifestFileName), comicManifestMaxBytes, check);
  final decoded = await decodeComicFolderManifestAsync(utf8.decode(bytes));
  check();
  final manifest = decoded.manifest;
  if (manifest == null || !decoded.fingerprintValid ||
      (manifest.format != comicManifestFormatV1 &&
        manifest.format != comicManifestFormatV2 &&
        manifest.format != comicManifestFormatV3) ||
      manifest.sourceId.trim().isEmpty || manifest.comicId.trim().isEmpty ||
      manifest.generation < 0 ||
      manifest.chapters.toSet().length != manifest.chapters.length ||
      manifest.chapterFiles.keys.any((id) => !manifest.chapters.contains(id))) {
    throw const FormatException('ZIC 清单无效或指纹不匹配');
  }
  for (final name in manifest.chapterDirectories.values) {
    externalChildPath('', name);
  }
  final ids = manifest.chapters.isEmpty ? ['local'] : manifest.chapters;
  if (ids.length > _maxEntries) throw const FormatException('ZIC 清单章节过多');
  var fileCount = 0;
  final usedDirectories = <String>{};
  final chapters = <ExternalDownloadChapter>[];
  for (final id in ids) {
    check();
    final title = manifest.chapterTitles[id] ??
        (ids.length == 1 ? manifest.comicTitle : id);
    final sequence = manifest.chapterSequences[id] ?? chapters.length + 1;
    final subdirectory = manifest.chapterDirectories[id] ??
        (ids.length == 1 ? null : buildChapterDirectoryName(title,
          fallbackIndex: sequence));
    final chapterPath = subdirectory == null ? directory
        : externalChildPath(directory, subdirectory);
    if (!usedDirectories.add(chapterPath)) {
      throw const FormatException('ZIC 清单的章节目录重复');
    }
    List<ExternalDownloadFile> files;
    if (subdirectory == null) {
      files = entries;
    } else {
      if (!entries.any((entry) => entry.isDirectory && entry.name == subdirectory)) {
        warnings.add('$title：清单中的章节目录缺失，已跳过');
        continue;
      }
      files = await tree.list(chapterPath);
      check();
    }
    fileCount += files.length;
    if (fileCount > _maxEntries) throw const FormatException('ZIC 清单目录项目过多');
    final existing = {for (final file in files)
      if (!file.isDirectory) file.name: file};
    final inventory = manifest.chapterFiles[id];
    final pages = <String>[];
    final proofs = <String, ComicPageFile>{};
    if (inventory != null) {
      if (inventory.pageCount > _maxEntries) {
        throw const FormatException('ZIC 清单单章页数过多');
      }
      for (final page in inventory.pages) {
        final file = existing[page.fileName];
        if (file == null || (file.length != null && file.length != page.bytes)) {
          warnings.add('$title · ${page.fileName}：文件缺失或长度不符，已跳过');
          continue;
        }
        final path = externalChildPath(chapterPath, page.fileName);
        pages.add(path);
        proofs[path] = page;
      }
      final listedNames = inventory.pages.map((page) => page.fileName).toSet();
      final unlisted = existing.keys.where((name) => _isExternalPage(name) &&
        !listedNames.contains(name)).length;
      if (unlisted > 0) warnings.add('$title：$unlisted 张图片不在 ZIC 清单中，未自动纳入');
    } else {
      pages.addAll(existing.keys.where(_isExternalPage).map(
        (name) => externalChildPath(chapterPath, name),
      ));
      pages.sort(_naturalCompare);
      warnings.add('$title：旧 ZIC 清单没有页面信息，按现有文件名恢复顺序');
    }
    if (pages.isEmpty) {
      warnings.add('$title：没有可导入的清单页面');
      continue;
    }
    chapters.add(ExternalDownloadChapter(path: chapterPath, title: title,
      pages: List.unmodifiable(pages), sequence: sequence,
      expectedPages: inventory?.pageCount, fileProofs: Map.unmodifiable(proofs),
      warning: inventory != null && pages.length < inventory.pageCount
        ? '原清单 ${inventory.pageCount} 页，现有 ${pages.length} 页；仅导入现有页面' : null));
  }
  chapters.sort((a, b) => a.sequence.compareTo(b.sequence));
  return ExternalDownloadComic(path: directory, title: manifest.comicTitle,
    format: ExternalDownloadFormat.zic, chapters: List.unmodifiable(chapters),
    foreignIdentity: jsonEncode([manifest.sourceId, manifest.comicId]));
}

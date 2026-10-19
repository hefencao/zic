part of 'external_download_import.dart';

final class _ExternalMetadata {
  const _ExternalMetadata({this.title, this.series, this.description,
    this.authors = const [], this.tags = const [], this.pageCount,
    this.identity, this.isEh = false});
  final String? title;
  final String? series;
  final String? description;
  final List<String> authors;
  final List<String> tags;
  final int? pageCount;
  final String? identity;
  final bool isEh;

  _ExternalMetadata mergeEh(Uint8List bytes) {
    // Legacy SpiderInfo VERSION2 and v1 are line based. Current binary
    // variants are intentionally not interpreted as a legacy page manifest.
    final lines = const LineSplitter().convert(utf8.decode(bytes, allowMalformed: true));
    final version2 = lines.isNotEmpty && lines.first == 'VERSION2';
    final offset = version2 ? 1 : 0;
    final legacy = version2 || (lines.isNotEmpty &&
        RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(lines.first));
    final gid = legacy && lines.length > offset + 6
        ? int.tryParse(lines[offset + 1]) : null;
    final count = legacy && lines.length > offset + 6
        ? int.tryParse(lines[offset + 6]) : null;
    return _ExternalMetadata(title: title, series: series, description: description,
      authors: authors, tags: tags,
      pageCount: count != null && count > 0 ? count : pageCount,
      identity: gid != null && gid > 0 ? 'eh:$gid' : identity, isEh: true);
  }
}

_ExternalMetadata _readComicInfo(Uint8List bytes) {
  final text = utf8.decode(bytes);
  if (RegExp(r'<!\s*(DOCTYPE|ENTITY)', caseSensitive: false).hasMatch(text)) {
    throw const FormatException('ComicInfo 不接受外部实体或 DTD');
  }
  final root = XmlDocument.parse(text).rootElement;
  if (root.name.local != 'ComicInfo') throw const FormatException('无效的 ComicInfo');
  String? value(String name) {
    final matches = root.childElements.where((e) => e.name.local == name);
    if (matches.length > 1) throw FormatException('ComicInfo 重复字段：$name');
    final result = matches.isEmpty ? '' : matches.single.innerText.trim();
    return result.isEmpty ? null : result;
  }
  List<String> list(String name) => (value(name) ?? '').split(',')
      .map((part) => part.trim()).where((part) => part.isNotEmpty).toList();
  final web = value('Web');
  final pageCount = int.tryParse(value('PageCount') ?? '');
  final isEh = web != null && RegExp(r'https?://(?:e-hentai|exhentai)\.org/g/\d+/')
      .hasMatch(web);
  return _ExternalMetadata(
    title: value('Title'), series: value('Series'), description: value('Summary'),
    authors: {...list('Writer'), ...list('Penciller')}.toList(),
    tags: {...list('Genre'), ...list('Tags'), ...list('CategoriesTachiyomi')}.toList(),
    pageCount: pageCount != null && pageCount > 0 ? pageCount : null,
    identity: web == null ? null : _digestText(web), isEh: isEh,
  );
}

final class _VeneraComic {
  _VeneraComic({required this.identity, required this.title,
    required this.directory, required this.tags, required this.chapters,
    required this.downloaded, required this.hasChapters});
  final String identity;
  final String title;
  final String directory;
  final List<String> tags;
  final Map<String, ({String title, int sequence, String id})> chapters;
  final Set<String> downloaded;
  final bool hasChapters;
  List<String> get authors => const [];
  String? get description => null;

  String? resolvePath(String input, Iterable<String> directories, String rootName) {
    // Old absolute roots may be relocated, but only a unique in-grant basename
    // is eligible. Never open the absolute path from the foreign database.
    final normalized = directory.replaceAll('\\', '/');
    if (normalized.split('/').contains('..')) return null;
    final basename = p.posix.basename(normalized);
    final candidates = directories.where((path) =>
        _externalDisplayName(path, rootName) == basename).toList();
    if (candidates.length == 1) {
      final path = candidates.single;
      if (path.isEmpty || input == path || input.startsWith('$path/')) return path;
    }
    return null;
  }
  bool matches(String input, Iterable<String> directories, String rootName) =>
      resolvePath(input, directories, rootName) != null;
  ({String title, int sequence, String id})? chapterForDirectory(String? name) =>
      name == null ? null : chapters[name];
  bool isDownloaded(String? name) {
    if (!hasChapters) return true;
    final chapter = chapterForDirectory(name);
    return chapter != null && downloaded.contains(chapter.id);
  }
}

Future<List<_VeneraComic>> _readVeneraDatabase(ExternalDownloadTree tree,
    String databasePath, void Function() check) async {
  final temp = await Directory.systemTemp.createTemp('zic-import-metadata-');
  try {
    final parent = p.posix.dirname(databasePath);
    final entries = await tree.list(parent == '.' ? '' : parent);
    final paths = [databasePath,
      if (entries.any((file) => file.name == '${p.posix.basename(databasePath)}-wal'))
        '$databasePath-wal'];
    final hashes = <String, String>{};
    for (final path in paths) {
      check();
      final file = File(p.join(temp.path, p.posix.basename(path)));
      await _copyExternalFile(tree, path, file, 128 * 1024 * 1024, check);
      hashes[path] = (await sha256.bind(file.openRead()).single).toString();
    }
    // A live WAL must accompany its database, and all captured bytes must stay
    // stable across the snapshot. Opening only a copied main file loses commits.
    for (final path in paths) {
      check();
      final hash = (await sha256.bind(_boundedExternalMetadataRead(tree, path, check)).single).toString();
      if (hash != hashes[path]) throw const FormatException('数据库正在变化，请关闭原 App 后重新导出');
    }
    final after = await tree.list(parent == '.' ? '' : parent);
    if (after.any((f) => f.name == '${p.posix.basename(databasePath)}-wal') !=
        (paths.length == 2)) {
      throw const FormatException('数据库 WAL 已变化，请关闭原 App 后重新导出');
    }
    check();
    final snapshotPath = p.join(temp.path, p.posix.basename(databasePath));
    return await _externalWorker(snapshotPath, _readVeneraSnapshot);
  } finally {
    await temp.delete(recursive: true);
  }
}

List<_VeneraComic> _readVeneraSnapshot(String snapshotPath) {
  final db = sqlite3.open(snapshotPath, mode: OpenMode.readOnly);
  try {
    db.execute('PRAGMA query_only = ON');
    db.execute('BEGIN');
    if (db.select('PRAGMA quick_check').single.values.single != 'ok') {
      throw const FormatException('Venera 数据库完整性检查失败');
    }
    final rows = db.select('SELECT id, title, tags, directory, chapters, '
        'comic_type, downloadedChapters FROM comics LIMIT 20001');
    if (rows.length > _maxEntries) throw const FormatException('数据库漫画数量过多');
    final result = <_VeneraComic>[];
    for (final row in rows) {
      final chapterJson = jsonDecode(row['chapters'] as String);
      final chapters = <String, ({String title, int sequence, String id})>{};
      var sequence = 0;
      void addChapters(Map values) {
        for (final entry in values.entries) {
          if (entry.value is Map) {
            addChapters(entry.value as Map);
          } else {
            final id = entry.key.toString();
            final name = id.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
            if (name.isEmpty || chapters.containsKey(name)) {
              throw const FormatException('Venera 章节目录名称冲突');
            }
            checkedExternalPath(name);
            chapters[name] = (title: entry.value.toString(), sequence: ++sequence, id: id);
          }
        }
      }
      if (chapterJson is Map) addChapters(chapterJson);
      result.add(_VeneraComic(
        identity: 'venera:${row['comic_type']}:${row['id']}',
        title: row['title'] as String, directory: row['directory'] as String,
        tags: List<String>.from(jsonDecode(row['tags'] as String) as List),
        chapters: chapters,
        hasChapters: chapterJson is Map,
        downloaded: Set<String>.from(jsonDecode(row['downloadedChapters'] as String) as List),
      ));
    }
    db.execute('COMMIT');
    return result;
  } finally {
    db.close();
  }
}

Stream<List<int>> _boundedExternalMetadataRead(ExternalDownloadTree tree,
    String path, void Function() check) async* {
  var length = 0;
  await for (final bytes in tree.read(path)) {
    check();
    length += bytes.length;
    if (length > 128 * 1024 * 1024) throw const FormatException('数据库文件过大');
    yield bytes;
  }
}

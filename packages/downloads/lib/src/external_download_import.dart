import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:catalog/catalog.dart';
import 'package:crypto/crypto.dart';
import 'package:domain/domain.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:storage/storage.dart';
import 'package:xml/xml.dart';

import 'artifact_bytes.dart';
import 'external_download_tree.dart';

part 'external_download_metadata.dart';
part 'external_download_archive.dart';
part 'external_download_zic.dart';

enum ExternalDownloadFormat { auto, localFolder, ehViewer, mihon, venera, zic }

String externalDownloadFormatName(ExternalDownloadFormat format) => switch (format) {
  ExternalDownloadFormat.auto => '自动识别',
  ExternalDownloadFormat.localFolder => '普通本地目录',
  ExternalDownloadFormat.ehViewer => 'EHViewer',
  ExternalDownloadFormat.mihon => 'Mihon / Tachiyomi',
  ExternalDownloadFormat.venera => 'Venera',
  ExternalDownloadFormat.zic => 'ZIC',
};

const _maxPageBytes = 128 * 1024 * 1024;
const _maxArchiveBytes = 4 * 1024 * 1024 * 1024;
const _maxMetadataBytes = 2 * 1024 * 1024;
const _maxEntries = comicManifestMaxEntries;

// Keep the isolate closure in a scope containing only its input and a top-level
// worker tear-off. A closure inside an import loop can otherwise retain shared
// context, including the caller's unsendable cancellation/lifetime state.
Future<T> _externalWorker<A, T>(A input, FutureOr<T> Function(A) worker) =>
    Isolate.run(() => worker(input));

/// Locators never become Reader locators: the durable record owns ZIC copies.
final class ExternalDownloadChapter {
  const ExternalDownloadChapter({required this.path, required this.title,
    required this.pages, this.archive = false, this.sequence = 0,
    this.expectedPages, this.warning, this.fileProofs = const {}});
  final String path;
  final String title;
  final List<String> pages;
  final bool archive;
  final int sequence;
  final int? expectedPages;
  final String? warning;
  final Map<String, ComicPageFile> fileProofs;
}

final class ExternalDownloadComic {
  const ExternalDownloadComic({required this.path, required this.title,
    required this.format, required this.chapters, this.authors = const [],
    this.tags = const [], this.description, this.foreignIdentity});
  final String path;
  final String title;
  final ExternalDownloadFormat format;
  final List<ExternalDownloadChapter> chapters;
  final List<String> authors;
  final List<String> tags;
  final String? description;
  final String? foreignIdentity;
  int get pageCount => chapters.fold(0, (sum, chapter) => sum + chapter.pages.length);
  bool get canReadDirectly => format == ExternalDownloadFormat.localFolder &&
      chapters.every((chapter) => !chapter.archive);
}

final class ExternalDownloadScan {
  const ExternalDownloadScan(this.comics, this.warnings);
  final List<ExternalDownloadComic> comics;
  final List<String> warnings;
}

/// Scanning reads only the granted tree. Foreign databases are metadata inputs,
/// never a replacement for ZIC's library/download indexes or READY proofs.
final class ExternalDownloadScanner {
  Future<ExternalDownloadScan> scan(ExternalDownloadTree tree, {
    ExternalDownloadFormat format = ExternalDownloadFormat.auto,
    void Function()? checkCancelled,
  }) async {
    void check() => checkCancelled?.call();
    final directories = <String, List<ExternalDownloadFile>>{};
    final warnings = <String>[];
    final nativeComics = <ExternalDownloadComic>[];
    final nativeRoots = <String>{};
    var count = 0;
    Future<void> walk(String directory, int depth) async {
      check();
      if (depth > 12) throw const FormatException('目录超过 12 层，请选择更具体的下载目录');
      final entries = await tree.list(directory);
      check();
      count += entries.length;
      if (count > _maxEntries) throw const FormatException('目录项目过多，请分批选择漫画目录');
      entries.sort((a, b) => _naturalCompare(a.name, b.name));
      directories[directory] = entries;
      if ((format == ExternalDownloadFormat.auto || format == ExternalDownloadFormat.zic) &&
          entries.any((entry) => !entry.isDirectory && entry.name == comicManifestFileName)) {
        nativeRoots.add(directory);
        try {
          final comic = await _scanZicComic(tree, directory, entries, warnings, check);
          // Root files already contributed to walk's entry budget.
          count += comic.chapters.where((chapter) => chapter.path != directory)
              .fold<int>(0, (sum, chapter) => sum + chapter.pages.length);
          if (count > _maxEntries) throw const FormatException('目录项目过多，请分批选择漫画目录');
          if (comic.chapters.isNotEmpty) nativeComics.add(comic);
        } on Object catch (error) {
          check();
          warnings.add('$directory：无法采用 ZIC 清单，$error');
        }
        return;
      }
      for (final entry in entries) {
        final path = externalChildPath(directory, entry.name);
        if (entry.isDirectory && !_skipExternalName(entry.name)) {
          await walk(path, depth + 1);
        }
      }
    }
    await walk('', 0);
    if (format == ExternalDownloadFormat.zic) {
      return ExternalDownloadScan(List.unmodifiable(nativeComics), List.unmodifiable(warnings));
    }
    final databasePaths = <String>[
      for (final directory in directories.entries)
        for (final file in directory.value)
          if (!file.isDirectory && file.name == 'local.db')
            externalChildPath(directory.key, file.name),
    ];
    final venera = <_VeneraComic>[];
    final veneraRoots = databasePaths.map((path) => p.posix.dirname(path)).toSet();
    if (format == ExternalDownloadFormat.venera || format == ExternalDownloadFormat.auto) {
      if (databasePaths.length == 1) {
        try {
          venera.addAll(await _readVeneraDatabase(tree, databasePaths.single, check));
        } on Object catch (error) {
          check();
          warnings.add('无法采用 Venera 数据库，使用文件目录：$error');
        }
      } else if (databasePaths.length > 1) {
        warnings.add('存在多个 local.db，未自动合并；请分别选择对应下载目录');
      }
    }
    final grouped = <String, List<ExternalDownloadChapter>>{};
    final metadata = <String, _ExternalMetadata>{};
    final formats = <String, ExternalDownloadFormat>{};
    final matchedVenera = <String, _VeneraComic>{};
    for (final directory in directories.entries) {
      check();
      if (nativeRoots.contains(directory.key)) continue;
      final files = directory.value.where((file) => !file.isDirectory).toList();
      final images = files.where((file) => _isExternalPage(file.name) ||
          ((format == ExternalDownloadFormat.auto || format == ExternalDownloadFormat.localFolder) &&
            !_skipExternalName(file.name) && RegExp(r'\.(jpe?g|png|gif|webp|avif|jxl|bmp|heic|heif)$',
              caseSensitive: false).hasMatch(file.name))).map(
        (file) => externalChildPath(directory.key, file.name),
      ).toList();
      // Ordinary folders also accept images with an absent/unusual extension,
      // matching the local-media header-based import contract.
      if (format == ExternalDownloadFormat.auto || format == ExternalDownloadFormat.localFolder) {
        for (final file in files) {
          if (_skipExternalName(file.name) || _isExternalPage(file.name) ||
              RegExp(r'^(cover|thumb|thumbnail)\.|\.(cbz|xml|db)(-wal|-shm)?$',
                caseSensitive: false).hasMatch(file.name)) continue;
          final path = externalChildPath(directory.key, file.name);
          try {
            if (await _externalHasImageHeader(tree, path, check)) images.add(path);
          } on Object catch (error) {
            check();
            warnings.add('$path：无法检查文件，$error');
          }
        }
        images.sort(_naturalCompare);
      }
      final inputs = <({String path, List<String> pages, bool archive})>[
        if (images.isNotEmpty) (path: directory.key, pages: images, archive: false),
        for (final file in files)
          if (!_skipExternalName(file.name) && file.name.toLowerCase().endsWith('.cbz'))
            (path: externalChildPath(directory.key, file.name), pages: const [], archive: true),
      ];
      for (final input in inputs) {
        try {
          check();
          var info = const _ExternalMetadata();
          var pages = input.pages;
          var eh = false;
          if (input.archive) {
            final archive = await _inspectExternalArchive(tree, input.path, check);
            pages = archive.pages;
            info = archive.metadata;
          } else {
            final xml = files.where((f) => f.name.toLowerCase() == 'comicinfo.xml');
            if (xml.length == 1) {
              info = _readComicInfo(await _readExternalBytes(
                tree, externalChildPath(directory.key, xml.single.name),
                _maxMetadataBytes, check,
              ));
            }
            if (files.any((f) => f.name == '.ehviewer')) {
              eh = true;
              info = info.mergeEh(await _readExternalBytes(
                tree, externalChildPath(directory.key, '.ehviewer'),
                _maxMetadataBytes, check,
              ));
              if (info.pageCount == null) {
                warnings.add('${input.path}：EHViewer 清单版本未知，仅采用现有图片，无法核对原始总页数');
              }
            }
          }
          if (pages.isEmpty) continue;
          if (pages.length > _maxEntries) throw const FormatException('单章页数过多');
          final effective = format != ExternalDownloadFormat.auto ? format
              : eh || info.isEh ? ExternalDownloadFormat.ehViewer
              : veneraRoots.any((root) => root == '.' || input.path == root ||
                  input.path.startsWith('$root/')) ? ExternalDownloadFormat.venera
              : info.hasComicInfo ? ExternalDownloadFormat.mihon
              : ExternalDownloadFormat.localFolder;
          if (!input.archive) {
            final body = pages.where((path) => !(effective == ExternalDownloadFormat.localFolder
                ? RegExp(r'^cover\.', caseSensitive: false)
                : RegExp(r'^(cover|thumb|thumbnail)\.', caseSensitive: false))
                  .hasMatch(p.posix.basename(path))).toList();
            pages = body.isEmpty && effective == ExternalDownloadFormat.localFolder
                ? pages.take(1).toList() : body;
            if (pages.isEmpty) continue;
          }
          var comicPath = effective == ExternalDownloadFormat.ehViewer
              ? (input.archive ? p.posix.dirname(input.path) : input.path)
              : effective == ExternalDownloadFormat.localFolder ? input.path
              : p.posix.dirname(input.path);
          if (comicPath == '.') comicPath = '';
          _VeneraComic? databaseComic;
          if (effective == ExternalDownloadFormat.venera) {
            final matches = venera.where((comic) => comic.matches(
              input.path, directories.keys, tree.displayName,
            ));
            if (matches.length == 1) {
              databaseComic = matches.single;
              comicPath = databaseComic.resolvePath(
                input.path, directories.keys, tree.displayName,
              )!;
              matchedVenera[comicPath] = databaseComic;
            } else if (matches.length > 1) {
              throw const FormatException('数据库目录对应多本漫画，无法安全确定归属');
            } else {
              if (venera.isNotEmpty) {
                warnings.add('${input.path}：未匹配 Venera 数据库目录，仅采用现有图片，无法确认原下载完整性或章节顺序');
              }
              if (!input.archive) {
                // Without a matching DB record, a parent cover is evidence for
                // Venera's chapter layout; otherwise keep leaves independent.
                final parentFiles = directories[comicPath] ?? const [];
                if (!parentFiles.any((f) => !f.isDirectory &&
                    f.name.toLowerCase().startsWith('cover.'))) {
                  comicPath = input.path;
                }
              }
            }
          }
          if (input.path.isEmpty) comicPath = '';
          final fallbackTitle = input.archive
              ? p.posix.basenameWithoutExtension(input.path)
              : _externalDisplayName(input.path, tree.displayName);
          final chapterKey = input.path == comicPath ? null : p.posix.basename(input.path);
          final dbChapter = databaseComic?.chapterForDirectory(chapterKey);
          if (databaseComic != null && !databaseComic.isDownloaded(chapterKey)) {
            warnings.add('$fallbackTitle：Venera 未标记下载完成，已跳过');
            continue;
          }
          final expected = info.pageCount;
          final warning = expected != null && expected > pages.length
              ? '原清单 $expected 页，现有 ${pages.length} 页；仅导入现有页面'
              : null;
          grouped.putIfAbsent(comicPath, () => []).add(ExternalDownloadChapter(
            path: input.path, pages: List.unmodifiable(pages), archive: input.archive,
            title: dbChapter?.title ?? info.title ?? fallbackTitle,
            sequence: dbChapter?.sequence ?? 0,
            expectedPages: expected, warning: warning,
          ));
          metadata.putIfAbsent(comicPath, () => info);
          formats[comicPath] = effective;
        } on Object catch (error) {
          check();
          warnings.add('${input.path}：未导入，$error');
        }
      }
    }
    final comics = <ExternalDownloadComic>[...nativeComics];
    for (final group in matchedVenera.entries) {
      final present = grouped[group.key]?.map((c) => p.posix.basename(c.path)).toSet() ?? <String>{};
      for (final chapter in group.value.chapters.entries) {
        if (group.value.downloaded.contains(chapter.value.id) && !present.contains(chapter.key)) {
          warnings.add('${group.value.title} · ${chapter.value.title}：数据库已标记下载，但目录中没有可导入图片');
        }
      }
    }
    for (final group in grouped.entries) {
      final info = metadata[group.key]!;
      final db = matchedVenera[group.key];
      group.value.sort((a, b) => a.sequence != b.sequence
          ? a.sequence.compareTo(b.sequence) : _naturalCompare(a.path, b.path));
      comics.add(ExternalDownloadComic(
        path: group.key,
        title: db?.title ?? info.series ??
            (formats[group.key] == ExternalDownloadFormat.ehViewer ? info.title : null) ??
            (group.value.singleOrNull?.archive == true
                ? p.posix.basenameWithoutExtension(group.key)
                : _externalDisplayName(group.key, tree.displayName)),
        format: formats[group.key]!, chapters: List.unmodifiable(group.value),
        authors: db?.authors ?? info.authors, tags: db?.tags ?? info.tags,
        description: db?.description ?? info.description,
        foreignIdentity: db?.identity ?? info.identity,
      ));
    }
    comics.sort((a, b) => _naturalCompare(a.path, b.path));
    if (comics.any((c) => c.format == ExternalDownloadFormat.venera) && venera.isEmpty) {
      warnings.add('未读取 Venera local.db：仅复制现有图片，不能确认原下载是否完整；章节标题与顺序按目录推断。可附带导出的 local.db 后重新扫描');
    }
    return ExternalDownloadScan(List.unmodifiable(comics), List.unmodifiable(warnings));
  }
}

/// Private staging belongs to one awaited import. Call dispose only after the
/// persistent download consumer has physically exited (including cancellation).
final class PreparedExternalChapter {
  PreparedExternalChapter._(this.record, this.files, this._directory);
  final ImportedChapterRecord record;
  final Map<Uri, File> files;
  final Directory _directory;
  Future<void>? _disposing;
  Future<void> dispose() => _disposing ??= _dispose();
  Future<void> _dispose() async {
    if (await _directory.exists()) await _directory.delete(recursive: true);
  }
}

/// File-system lifetime of one import operation. Presentation holds this
/// capability, never a Directory/descriptor or an independent byte index.
final class ExternalDownloadImportRun {
  ExternalDownloadImportRun._(this._rootKey, this._directory);
  final String _rootKey;
  final Directory _directory;
  static final Set<String> _activeRoots = {};
  Future<void>? _disposing;

  static Future<ExternalDownloadImportRun> open(String stagingRoot, {
    void Function()? checkCancelled,
  }) async {
    final directory = Directory(stagingRoot).absolute;
    final key = directory.path;
    if (!_activeRoots.add(key)) throw StateError('已有外部下载导入任务');
    try {
      await directory.create(recursive: true);
      await for (final entity in directory.list(followLinks: false)) {
        checkCancelled?.call();
        if (entity is Directory && p.basename(entity.path).startsWith('run-')) {
          await entity.delete(recursive: true);
        }
      }
      checkCancelled?.call();
      return ExternalDownloadImportRun._(key, await directory.createTemp('run-'));
    } on Object {
      _activeRoots.remove(key);
      rethrow;
    }
  }

  Future<PreparedExternalChapter> prepare({
    required ExternalDownloadTree tree,
    required ExternalDownloadComic comic,
    required ExternalDownloadChapter chapter,
    void Function()? checkCancelled,
  }) {
    if (_disposing != null) throw StateError('导入暂存已关闭');
    return prepareExternalChapter(tree: tree, comic: comic, chapter: chapter,
      stagingParent: _directory, checkCancelled: checkCancelled);
  }

  Future<void> dispose() => _disposing ??= _dispose();
  Future<void> _dispose() async {
    try {
      if (await _directory.exists()) await _directory.delete(recursive: true);
    } finally {
      _activeRoots.remove(_rootKey);
    }
  }
}

Future<PreparedExternalChapter> prepareExternalChapter({
  required ExternalDownloadTree tree,
  required ExternalDownloadComic comic,
  required ExternalDownloadChapter chapter,
  required Directory stagingParent,
  void Function()? checkCancelled,
  void Function(int completedPages)? onProgress,
}) async {
  void check() => checkCancelled?.call();
  check();
  await stagingParent.create(recursive: true);
  final stage = await stagingParent.createTemp('chapter-');
  try {
    File? archive;
    if (chapter.archive) {
      archive = File(p.join(stage.path, 'input.cbz'));
      await _copyExternalFile(tree, chapter.path, archive, _maxArchiveBytes, check);
    }
    final pages = <ImportedPageRecord>[];
    final files = <Uri, File>{};
    // A local namespace prevents accidental equivalence with plugin IDs. The
    // granted root participates even when a foreign ID is available: a copied
    // library with the same title/ID is not silently merged with another root.
    final comicKey = _digestText(jsonEncode([
      tree.identity, comic.format.name, comic.path,
    ]));
    final chapterKey = _digestText('$comicKey\u0000${chapter.path}');
    for (var i = 0; i < chapter.pages.length; i++) {
      check();
      final file = File(p.join(stage.path, 'page-$i'));
      final source = chapter.pages[i];
      if (archive == null) {
        await _copyExternalFile(tree, source, file, _maxPageBytes, check);
      } else {
        await _externalWorker(
          (archive: archive.path, name: source, target: file.path),
          _extractExternalPage,
        );
      }
      check();
      final proof = await _proveExternalPage(file);
      check();
      final expected = chapter.fileProofs[source];
      if (expected != null) {
        final checksum = switch (expected.checksumAlgorithm.trim().toLowerCase()) {
          'crc32' => proof.crc32,
          'sha256' => proof.hash,
          _ => throw FormatException('不支持的清单校验算法：${expected.checksumAlgorithm}'),
        };
        if (proof.length != expected.bytes || checksum != expected.checksum.trim().toLowerCase()) {
          throw FormatException('ZIC 清单文件校验失败：$source');
        }
      }
      // The existing physical-media resolver recognizes the first URI digest
      // as content identity. Only the independently measured page SHA belongs
      // here; comic/chapter hashes would incorrectly merge different pages.
      final uri = Uri(scheme: 'zic-import', host: 'sha256',
        pathSegments: [proof.hash, '$i']);
      pages.add(ImportedPageRecord(
        displayName: p.posix.basename(source), sourceId: uri.toString(),
        pageId: 'import-$i-${proof.hash}',
        contentKindHint: switch (proof.extension) {
          'jpg' => ContentKindHint.jpeg,
          'png' => ContentKindHint.png,
          'gif' => ContentKindHint.gif,
          'webp' => ContentKindHint.webp,
          'avif' => ContentKindHint.avif,
          _ => ContentKindHint.fallback,
        },
        mediaFormat: proof.extension, byteLength: proof.length,
        checksum: proof.crc32, checksumAlgorithm: 'crc32',
        animatedHint: proof.extension == 'gif' || proof.extension == 'webp',
      ));
      files[uri] = file;
      onProgress?.call(i + 1);
    }
    if (pages.isEmpty) throw const FormatException('没有可导入的图片');
    final record = ImportedChapterRecord(
      directoryId: 'zic-import:$comicKey/$chapterKey',
      displayName: chapter.title, sourceId: externalDownloadsSourceId,
      comicId: 'import-$comicKey', chapterId: 'import-$chapterKey',
      sourceRevision: _digestText(jsonEncode([
        comic.title, chapter.title, for (final page in pages) page.toJson(),
      ])),
      comicTitle: comic.title, comicAuthors: comic.authors,
      comicTags: comic.tags, comicDescription: comic.description,
      sequence: comic.chapters.indexOf(chapter) + 1,
      pages: pages, coverSourceId: pages.first.sourceId,
      coverMediaFormat: pages.first.mediaFormat,
      coverAnimatedHint: pages.first.animatedHint,
    );
    return PreparedExternalChapter._(record, Map.unmodifiable(files), stage);
  } on Object {
    await stage.delete(recursive: true);
    rethrow;
  }
}

Future<void> _copyExternalFile(ExternalDownloadTree tree, String path,
    File target, int limit, void Function() check) async {
  final sink = await target.open(mode: FileMode.writeOnly);
  var length = 0;
  try {
    await for (final chunk in tree.read(checkedExternalPath(path))) {
      check();
      length += chunk.length;
      if (length > limit) throw FormatException('文件超过导入上限：$path');
      await sink.writeFrom(chunk);
    }
    check();
  } finally {
    await sink.close();
  }
}

Future<Uint8List> _readExternalBytes(ExternalDownloadTree tree, String path,
    int limit, void Function() check) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in tree.read(checkedExternalPath(path))) {
    check();
    if (bytes.length + chunk.length > limit) throw FormatException('清单过大：$path');
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

Future<({String hash, String crc32, String extension, int length})>
    _proveExternalPage(File file) => _externalWorker(file.path, _proveExternalPageAtPath);

Future<({String hash, String crc32, String extension, int length})>
    _proveExternalPageAtPath(String path) async {
  final input = await File(path).open();
  late final String extension;
  try {
    extension = sniffImageExtensionFromBytes(await input.read(128));
  } finally {
    await input.close();
  }
  if (extension == 'bin') throw const FormatException('文件不是可识别的图片');
  final crc = Crc32();
  final hash = await sha256.bind(File(path).openRead().map((bytes) {
    crc.add(bytes);
    return bytes;
  })).single;
  final length = await File(path).length();
  if (length == 0 || length > _maxPageBytes) throw const FormatException('图片大小无效');
  return (hash: hash.toString(), crc32: crc.hex, extension: extension, length: length);
}

String _digestText(String text) => sha256.convert(utf8.encode(text)).toString();
Future<bool> _externalHasImageHeader(ExternalDownloadTree tree, String path,
    void Function() check) async {
  final prefix = BytesBuilder(copy: false);
  await for (final chunk in tree.read(path)) {
    check();
    prefix.add(chunk.length > 128 - prefix.length
        ? chunk.sublist(0, 128 - prefix.length) : chunk);
    if (prefix.length >= 128) break;
  }
  check();
  return sniffImageExtensionFromBytes(prefix.takeBytes()) != 'bin';
}
String _externalDisplayName(String path, String fallback) =>
    path.isEmpty || path == '.' ? fallback : p.posix.basename(path);
bool _skipExternalName(String name) => name.startsWith('.') ||
    name.toLowerCase().endsWith('_tmp') || name.toLowerCase().endsWith('.tmp') ||
    name == '__MACOSX';
bool _isExternalPage(String name) => !_skipExternalName(name) &&
    !RegExp(r'^(cover|thumb|thumbnail)\.', caseSensitive: false).hasMatch(name) &&
    (RegExp(r'\.(jpe?g|png|gif|webp|avif|jxl|bmp|heic|heif)$',
        caseSensitive: false).hasMatch(name) || RegExp(r'^\d+$').hasMatch(name));
int _naturalCompare(String left, String right) {
  final pattern = RegExp(r'\d+|\D+');
  final a = pattern.allMatches(left.toLowerCase()).map((m) => m[0]!).toList();
  final b = pattern.allMatches(right.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < a.length && i < b.length; i++) {
    final x = BigInt.tryParse(a[i]);
    final y = BigInt.tryParse(b[i]);
    final order = x != null && y != null ? x.compareTo(y) : a[i].compareTo(b[i]);
    if (order != 0) return order;
  }
  final order = a.length.compareTo(b.length);
  return order == 0 ? left.compareTo(right) : order;
}

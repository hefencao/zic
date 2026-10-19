import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:catalog/catalog.dart';
import 'package:downloads/downloads.dart';
import 'package:sessions/sessions.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6jXcAAAAASUVORK5CYII=');

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('zic-external-import-test-'));
  tearDown(() async { if (await root.exists()) await root.delete(recursive: true); });

  Future<File> write(String path, List<int> bytes) async {
    final file = File('${root.path}/$path');
    await file.parent.create(recursive: true);
    return file.writeAsBytes(bytes);
  }

  test('EHViewer legacy manifest preserves natural page order and reports a partial gallery', () async {
    await write('foreign/Gallery/00000010.jpg', _png);
    await write('foreign/Gallery/00000002.jpg', _png);
    await write('foreign/Gallery/cover.jpg', _png);
    await write('foreign/Gallery/00000003.jpg.tmp', _png);
    await write('foreign/Gallery/.ehviewer', utf8.encode('VERSION2\n00000000\n123\ntoken\n1\n2\n40\n10\n0 ptoken\n'));
    final tree = DirectoryExternalDownloadTree('${root.path}/foreign');
    final scan = await ExternalDownloadScanner().scan(tree);
    expect(scan.warnings, isEmpty);
    expect(scan.comics, hasLength(1));
    final comic = scan.comics.single;
    expect(comic.format, ExternalDownloadFormat.ehViewer);
    expect(comic.title, 'Gallery');
    final chapter = comic.chapters.single;
    expect(chapter.pages.map((path) => path.split('/').last), ['00000002.jpg', '00000010.jpg']);
    expect(chapter.expectedPages, 10);
    expect(chapter.warning, contains('仅导入现有页面'));
  });

  test('Mihon folders and CBZ share a comic; tmp, covers and split pages are handled', () async {
    await write('foreign/Source/Series/Chapter 2_hash/001__002.jpg', _png);
    await write('foreign/Source/Series/Chapter 2_hash/001__001.jpg', _png);
    await write('foreign/Source/Series/Chapter 2_hash/ComicInfo.xml', utf8.encode(
      '<ComicInfo><Series>True series</Series><Title>Chapter Two</Title><Writer>A</Writer></ComicInfo>'));
    await write('foreign/Source/Series/Chapter 99_tmp/001.jpg', _png);
    await write('foreign/Source/Series/Chapter 3.cbz_tmp', _png);
    final archive = Archive()
      ..add(ArchiveFile('10.png', _png.length, _png))
      ..add(ArchiveFile('2.png', _png.length, _png))
      ..add(ArchiveFile('cover.jpg', _png.length, _png))
      ..add(ArchiveFile.string('ComicInfo.xml', '<ComicInfo><Series>True series</Series><Title>Chapter One</Title></ComicInfo>'));
    await write('foreign/Source/Series/Chapter 1.cbz', ZipEncoder().encode(archive));
    final tree = DirectoryExternalDownloadTree('${root.path}/foreign');
    final scan = await ExternalDownloadScanner().scan(tree, format: ExternalDownloadFormat.mihon);
    expect(scan.warnings, isEmpty);
    final comic = scan.comics.single;
    expect(comic.title, 'True series');
    expect(comic.chapters.map((chapter) => chapter.title), ['Chapter One', 'Chapter Two']);
    expect(comic.pageCount, 4);
    expect(comic.chapters.first.pages, ['2.png', '10.png']);
    final prepared = await prepareExternalChapter(tree: tree, comic: comic,
      chapter: comic.chapters.first, stagingParent: Directory('${root.path}/stage'));
    addTearDown(prepared.dispose);
    expect(prepared.record.pages.map((page) => page.displayName), ['2.png', '10.png']);
    expect(await prepared.files.values.first.readAsBytes(), _png);
  });

  test('Venera reads an uncheckpointed WAL snapshot and maps grouped IDs, not titles', () async {
    final cancellationPort = ReceivePort();
    addTearDown(cancellationPort.close);
    void check() => expect(cancellationPort.sendPort, isA<SendPort>());
    final dbFile = await write('foreign/local.db', []);
    final db = sqlite3.open(dbFile.path);
    addTearDown(db.close);
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA wal_autocheckpoint=0');
    db.execute('CREATE TABLE comics(id TEXT,title TEXT,tags TEXT,directory TEXT,chapters TEXT,comic_type INTEGER,downloadedChapters TEXT)');
    db.execute('INSERT INTO comics VALUES(?,?,?,?,?,?,?)', ['same-id', 'Venera title', '["tag"]', '/old/device/Comic',
      '{"Group":{"ep/9":"First","ep:2":"Second","ep3":"Incomplete"}}', 4, '["ep/9","ep:2"]']);
    await write('foreign/Comic/ep_9/0.jpg', _png);
    await write('foreign/Comic/ep_2/0.jpg', _png);
    await write('foreign/Comic/ep3/0.jpg', _png);
    final before = await File('${dbFile.path}-wal').readAsBytes();
    final tree = DirectoryExternalDownloadTree('${root.path}/foreign');
    final scan = await ExternalDownloadScanner().scan(tree, checkCancelled: check);
    expect(scan.warnings, hasLength(1));
    expect(scan.warnings.single, contains('未标记下载完成'));
    final comic = scan.comics.single;
    expect(comic.title, 'Venera title');
    expect(comic.tags, ['tag']);
    expect(comic.chapters.map((c) => c.title), ['First', 'Second']);
    expect(comic.chapters.map((c) => c.path), ['Comic/ep_9', 'Comic/ep_2']);
    expect(await File('${dbFile.path}-wal').readAsBytes(), before,
      reason: 'foreign databases, WALs and media must remain untouched');
    await write('foreign/Unmapped/0.jpg', _png);
    final unmatched = await ExternalDownloadScanner().scan(tree, checkCancelled: check);
    expect(unmatched.comics, hasLength(2));
    expect(unmatched.warnings, contains(contains('未匹配 Venera 数据库目录')));
  });

  test('import uses durable promotion, structured manifests and library records after originals disappear', () async {
    await write('foreign/Gallery/1.png', _png);
    final tree = DirectoryExternalDownloadTree('${root.path}/foreign');
    final comic = (await ExternalDownloadScanner().scan(tree, format: ExternalDownloadFormat.ehViewer)).comics.single;
    final prepared = await prepareExternalChapter(tree: tree, comic: comic,
      chapter: comic.chapters.single, stagingParent: Directory('${root.path}/stage'));
    final entry = ImportedLibraryEntry(chapter: prepared.record);
    final library = SqliteImportedLibraryStore('${root.path}/zic/library.sqlite');
    await Directory('${root.path}/zic').create();
    await library.open();
    await library.upsertChapter(entry.chapter);
    await library.close();
    Future<PersistentDownloadComposition> open() => PersistentDownloadComposition.open(
      '${root.path}/zic', indexPath: defaultChapterDownloadMetadataPath('${root.path}/zic'),
      transferNet: NetLane(maxActive: 5),
    );
    var composition = await open();
    var service = composition.chapterDownloads;
    await service.importLocalChapter(entry, prepared.files);
    expect((await service.inspect(entry)).phase, ChapterDownloadPhase.complete);
    expect((await service.inspect(entry)).pinnedPages, 1);
    final exported = await Directory('${root.path}/zic/offline_chapters').list(recursive: true).toList();
    final manifest = exported.whereType<File>().singleWhere((file) => file.path.endsWith('/.zic.json'));
    expect(ComicFolderManifest.decode(await manifest.readAsString())?.sourceId, externalDownloadsSourceId);
    expect(File('${root.path}/zic/chapter_downloads.sqlite').existsSync(), true);
    expect(exported.any((file) => file.path.endsWith('/001.png')), true);
    await composition.close();
    await prepared.dispose();
    await Directory('${root.path}/foreign').delete(recursive: true);
    composition = await open();
    service = composition.chapterDownloads;
    addTearDown(composition.close);
    await library.open();
    addTearDown(library.close);
    final restored = (await library.get(entry.chapter.sourceId, entry.chapter.chapterId))!;
    expect((await service.inspect(restored)).completedPages, 1);
    expect(await service.readPage(restored, 0), _png);
    await service.delete(restored);
    expect(await service.hasReadyPage(restored, 0), false);
  });

  test('repeated preparation has stable identities and detects changed page bytes', () async {
    await write('foreign/Comic/1.png', _png);
    final tree = DirectoryExternalDownloadTree('${root.path}/foreign');
    final comic = (await ExternalDownloadScanner().scan(tree, format: ExternalDownloadFormat.ehViewer)).comics.single;
    Future<PreparedExternalChapter> prepare() => prepareExternalChapter(tree: tree,
      comic: comic, chapter: comic.chapters.single, stagingParent: Directory('${root.path}/stage'));
    final first = await prepare();
    final second = await prepare();
    expect(second.record.comicId, first.record.comicId);
    expect(second.record.chapterId, first.record.chapterId);
    expect(second.record.sourceRevision, first.record.sourceRevision);
    await write('foreign/Comic/1.png', [..._png, 0]);
    final changed = await prepare();
    expect(changed.record.comicId, first.record.comicId);
    expect(changed.record.sourceRevision, isNot(first.record.sourceRevision));
    await first.dispose(); await second.dispose(); await changed.dispose();
  });

  test('path escapes, symlinks, malicious CBZ names and fake image bodies are refused', () async {
    for (final path in ['../file', '/absolute', 'a/../b', 'C:/file', 'a\\b', 'a//b', 'a/./b', 'bad\u0000']) {
      expect(() => checkedExternalPath(path), throwsFormatException);
    }
    await write('outside.png', _png);
    await Directory('${root.path}/foreign').create();
    await Link('${root.path}/foreign/escape').create('${root.path}/outside.png');
    final tree = DirectoryExternalDownloadTree('${root.path}/foreign');
    expect(await tree.list(''), isEmpty);
    await expectLater(tree.read('escape').drain<void>(), throwsFormatException);
    final archive = Archive()..add(ArchiveFile('../escape.png', _png.length, _png));
    await write('foreign/Series/Chapter.cbz', ZipEncoder().encode(archive));
    var scan = await ExternalDownloadScanner().scan(tree, format: ExternalDownloadFormat.mihon);
    expect(scan.comics, isEmpty);
    expect(scan.warnings, hasLength(1));
    await write('foreign/Fake/1.jpg', utf8.encode('<html>Access denied</html>'));
    scan = await ExternalDownloadScanner().scan(tree, format: ExternalDownloadFormat.ehViewer);
    final comic = scan.comics.single;
    await expectLater(prepareExternalChapter(tree: tree, comic: comic,
      chapter: comic.chapters.single, stagingParent: Directory('${root.path}/stage')), throwsFormatException);
    expect(await Directory('${root.path}/stage').list().toList(), isEmpty);
  });

  test('cancel during a source copy waits for the source to close and removes staging', () async {
    final exited = Completer<void>();
    var stop = false;
    final tree = _ControlledTree(() async* {
      try {
        yield _png;
        stop = true;
        yield _png;
      } finally {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        exited.complete();
      }
    });
    final comic = (await ExternalDownloadScanner().scan(tree)).comics.single;
    await expectLater(prepareExternalChapter(tree: tree, comic: comic,
      chapter: comic.chapters.single, stagingParent: Directory('${root.path}/stage'),
      checkCancelled: () { if (stop) throw StateError('cancel'); }), throwsStateError);
    expect(exited.isCompleted, true);
    expect(await Directory('${root.path}/stage').list().toList(), isEmpty);
  });

  test('a CBZ image with corrupt CRC cannot be published as an imported chapter', () async {
    final archive = Archive()..add(ArchiveFile('1.png', _png.length, _png));
    final bytes = ZipEncoder().encode(archive);
    for (var i = 0; i < bytes.length - 20; i++) {
      if (bytes[i] == 0x50 && bytes[i + 1] == 0x4b &&
          bytes[i + 2] == 0x01 && bytes[i + 3] == 0x02) {
        bytes[i + 16] ^= 1;
        break;
      }
    }
    await write('foreign/Comic/Chapter.cbz', bytes);
    final tree = DirectoryExternalDownloadTree('${root.path}/foreign');
    final comic = (await ExternalDownloadScanner().scan(tree)).comics.single;
    await expectLater(prepareExternalChapter(tree: tree, comic: comic,
      chapter: comic.chapters.single, stagingParent: Directory('${root.path}/stage')), throwsFormatException);
    expect(await Directory('${root.path}/stage').list().toList(), isEmpty);
  });

  test('archive workers never capture the caller cancellation context', () async {
    final port = ReceivePort();
    addTearDown(port.close);
    var checks = 0;
    void check() {
      checks++;
      expect(port.sendPort, isA<SendPort>());
    }
    final archive = Archive()..add(ArchiveFile('1.png', _png.length, _png));
    await write('foreign/Comic/Chapter.cbz', ZipEncoder().encode(archive));
    final tree = DirectoryExternalDownloadTree('${root.path}/foreign');
    final comic = (await ExternalDownloadScanner().scan(tree,
      checkCancelled: check)).comics.single;
    final prepared = await prepareExternalChapter(tree: tree, comic: comic,
      chapter: comic.chapters.single, stagingParent: Directory('${root.path}/stage'),
      checkCancelled: check);
    addTearDown(prepared.dispose);
    expect(await prepared.files.values.single.readAsBytes(), _png);
    expect(checks, greaterThan(0));
  });

  test('SAF sources open read-only and close descriptors before staging disposal', () async {
    final io = _ReadOnlySaf(_png);
    final tree = SafExternalDownloadTree(io: io,
      identity: 'saf://fixture', displayName: 'Fixture');
    final comic = (await ExternalDownloadScanner().scan(tree)).comics.single;
    final run = await ExternalDownloadImportRun.open('${root.path}/stage');
    final prepared = await run.prepare(tree: tree, comic: comic, chapter: comic.chapters.single);
    expect(io.closed, true);
    expect(await prepared.files.values.single.readAsBytes(), _png);
    await Future.wait([prepared.dispose(), prepared.dispose()]);
    await Future.wait([run.dispose(), run.dispose()]);
    final replacement = await ExternalDownloadImportRun.open('${root.path}/stage');
    await run.dispose();
    await expectLater(ExternalDownloadImportRun.open('${root.path}/stage'), throwsStateError,
      reason: 'old idempotent disposal cannot release a newer active run');
    await replacement.dispose();
  });
}

final class _ReadOnlySaf implements SafTreeIo {
  _ReadOnlySaf(this.bytes);
  final Uint8List bytes;
  var offset = 0;
  var closed = true;
  @override
  Future<List<SafTreeFile>> list(String relativePath) async => [
    SafTreeFile(name: '1.png', isDirectory: false, length: bytes.length),
  ];
  @override
  Future<int?> open(String path, {SafWriteMode mode = SafWriteMode.read}) async {
    expect(mode, SafWriteMode.read);
    expect(path, '1.png');
    offset = 0; closed = false;
    return 1;
  }
  @override
  Future<Uint8List> read(int handle, int length) async {
    final end = (offset + length).clamp(0, bytes.length);
    final result = Uint8List.sublistView(bytes, offset, end);
    offset = end;
    return result;
  }
  @override
  Future<void> close(int handle) async { closed = true; }
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected mutation/access on foreign SAF tree: ${invocation.memberName}');
}

final class _ControlledTree implements ExternalDownloadTree {
  _ControlledTree(this._read);
  final Stream<List<int>> Function() _read;
  @override
  String get identity => 'fixture';
  @override
  String get displayName => 'fixture';
  @override
  Future<List<ExternalDownloadFile>> list(String directory) async => [
    const ExternalDownloadFile('1.png'),
  ];
  @override
  Stream<List<int>> read(String path) => _read();
}

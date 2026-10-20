import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6jXcAAAAASUVORK5CYII=');

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('zic-manifest-import-'));
  tearDown(() async => root.delete(recursive: true));

  Future<void> write(String path, List<int> bytes) async {
    final file = File('${root.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  }

  ComicFolderManifest manifest({String format = comicManifestFormatV2,
    Map<String, ComicChapterFileList>? files}) => ComicFolderManifest(
      format: format, sourceId: 'remote-source', comicId: 'remote-comic',
      comicTitle: 'Recovered title', chapters: const ['chapter'],
      chapterTitles: const {'chapter': 'Recovered chapter'},
      chapterFiles: files ?? {'chapter': ComicChapterFileList(
        sourceRevision: 'revision', pageCount: 2, pages: [
          for (var i = 0; i < 2; i++) ComicPageFile(logicalIndex: i,
            pageId: 'page-$i', fileName: i == 0 ? '002.png' : '001.png',
            bytes: _png.length, checksum: (Crc32()..add(_png)).hex,
            checksumAlgorithm: 'crc32'),
        ])}, updatedAt: DateTime.utc(2026, 10, 20));

  Future<void> writeManifest(ComicFolderManifest draft) => write('Comic/.zic.json',
      utf8.encode(draft.copyWith(fingerprint: draft.computedFingerprint).encode()));

  test('ZIC file list restores logical order, titles and copy-only import', () async {
    await write('Comic/001.png', _png);
    await write('Comic/002.png', _png);
    await write('Comic/999.png', _png);
    await writeManifest(manifest());
    final tree = DirectoryExternalDownloadTree(root.path);
    final callerPort = ReceivePort();
    addTearDown(callerPort.close);
    void check() => expect(callerPort.sendPort, isA<SendPort>());
    final scan = await ExternalDownloadScanner().scan(tree, checkCancelled: check);
    final comic = scan.comics.single;
    expect(comic.format, ExternalDownloadFormat.zic);
    expect(comic.canReadDirectly, isFalse);
    expect(comic.title, 'Recovered title');
    expect(comic.chapters.single.title, 'Recovered chapter');
    expect(comic.chapters.single.pages, ['Comic/002.png', 'Comic/001.png']);
    expect(scan.warnings, [contains('不在 ZIC 清单中')]);
    final prepared = await prepareExternalChapter(tree: tree, comic: comic,
      chapter: comic.chapters.single, stagingParent: Directory('${root.path}/stage'),
      checkCancelled: check);
    addTearDown(prepared.dispose);
    expect(prepared.record.sourceId, externalDownloadsSourceId);
    expect(prepared.record.comicId, isNot('remote-comic'));
    expect(prepared.record.pages.map((page) => page.displayName), ['002.png', '001.png']);
  });

  test('missing, changed and duplicate manifest pages never gain READY proof', () async {
    await write('Comic/002.png', _png);
    await writeManifest(manifest());
    final tree = DirectoryExternalDownloadTree(root.path);
    var scan = await ExternalDownloadScanner().scan(tree);
    expect(scan.comics.single.chapters.single.pages, ['Comic/002.png']);
    expect(scan.comics.single.chapters.single.warning, contains('原清单 2 页'));
    final changed = [..._png]..[40] ^= 1;
    await write('Comic/002.png', changed);
    await expectLater(prepareExternalChapter(tree: tree, comic: scan.comics.single,
      chapter: scan.comics.single.chapters.single, stagingParent: Directory('${root.path}/stage')),
      throwsA(isA<FormatException>()));
    expect(await Directory('${root.path}/stage').list().toList(), isEmpty);
    final raw = manifest().toJson();
    final pages = ((raw['chapterFiles'] as Map)['chapter'] as Map)['pages'] as List;
    pages[1] = pages[0];
    await write('Comic/.zic.json', utf8.encode(jsonEncode(raw)));
    scan = await ExternalDownloadScanner().scan(tree);
    expect(scan.comics, isEmpty);
    expect(scan.warnings, [contains('无法采用 ZIC 清单')]);
  });

  test('legacy ZIC manifests recover without silently offering direct reading', () async {
    await write('Comic/010.png', _png);
    await write('Comic/002.png', _png);
    await writeManifest(manifest(format: comicManifestFormatV1, files: {}));
    final scan = await ExternalDownloadScanner().scan(DirectoryExternalDownloadTree(root.path));
    expect(scan.comics.single.chapters.single.pages, ['Comic/002.png', 'Comic/010.png']);
    expect(scan.comics.single.canReadDirectly, isFalse);
    expect(scan.warnings, [contains('旧 ZIC 清单')]);
  });

  test('unsafe or unknown manifests fail closed instead of becoming ordinary folders', () async {
    await write('Comic/001.png', _png);
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (unknown) => unknown['format'] = 'zic-comic-future',
      (unsafeDirectory) => unsafeDirectory['chapterDirectories'] = {'chapter': '../outside'},
      (badFingerprint) => badFingerprint['fingerprint'] = 'wrong',
      (unsafePage) => (((unsafePage['chapterFiles'] as Map)['chapter'] as Map)['pages'] as List)
        .first['file'] = '../outside.png',
    ]) {
      final raw = manifest().toJson();
      mutate(raw);
      await write('Comic/.zic.json', utf8.encode(jsonEncode(raw)));
      final scan = await ExternalDownloadScanner().scan(DirectoryExternalDownloadTree(root.path));
      expect(scan.comics, isEmpty);
      expect(scan.warnings, [contains('无法采用 ZIC 清单')]);
    }
  });

  test('production download, flat migration and deletion keep portable file lists', () async {
    final service = await PersistentChapterDownloadService.open('${root.path}/downloads');
    addTearDown(service.close);
    service.setChapterResourceAccess(ChapterResourceAccess(loadBytes: (_, __) async => _png));
    ImportedLibraryEntry chapter(String id, int sequence) => ImportedLibraryEntry(
      chapter: ImportedChapterRecord(directoryId: 'venera:$id', displayName: 'Title $id',
        sourceId: 'venera:test', comicId: 'comic', comicTitle: 'Comic', chapterId: id,
        sourceRevision: 'r1', sequence: sequence, pages: [ImportedPageRecord(
          displayName: 'image.png', sourceId: 'venera-resource:$id', pageId: '$id-page',
          contentKindHint: ContentKindHint.png)]));
    final first = chapter('first', 1);
    final second = chapter('second', 2);
    await service.download(first);
    await service.download(second);
    final tree = DirectoryExternalDownloadTree('${service.artifactStore.layout.root}/Comic');
    final scan = await ExternalDownloadScanner().scan(tree);
    expect(scan.warnings, isEmpty);
    expect(scan.comics.single.chapters.map((c) => c.title), ['Title first', 'Title second']);
    expect(scan.comics.single.chapters.map((c) => c.pages.single),
      ['Title first/001.png', 'Title second/001.png']);
    final manifestFile = File('${tree.root.path}/.zic.json');
    var saved = ComicFolderManifest.decode(await manifestFile.readAsString())!;
    expect(saved.format, comicManifestFormatV2);
    expect(saved.chapterFiles.keys.toSet(), {'first', 'second'});
    expect(saved.fingerprintValid, isTrue);
    final pageOrder = saved.pageOrder;
    await service.delete(first);
    saved = ComicFolderManifest.decode(await manifestFile.readAsString())!;
    expect(saved.chapterFiles.keys, ['second']);
    expect(saved.pageOrder, pageOrder);
    expect(saved.fingerprintValid, isTrue);
    final restored = (await ExternalDownloadScanner().scan(tree)).comics.single;
    expect(restored.chapters.single.pages, ['Title second/001.png']);
  });
}

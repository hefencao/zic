import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

ImportedLibraryEntry _entry(String comic, List<String> uris) => ImportedLibraryEntry(
  chapter: ImportedChapterRecord(directoryId: 'venera:$comic', displayName: 'Chapter',
    comicTitle: comic, sourceId: 'venera:test', comicId: comic,
    chapterId: 'chapter', sourceRevision: 'r1', pages: [
      for (var i = 0; i < uris.length; i++) ImportedPageRecord(displayName: '$i.webp',
        sourceId: uris[i], pageId: '$comic-$i', contentKindHint: ContentKindHint.webp),
    ]),
);

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('scoped-candidates-'));
  tearDown(() async => root.delete(recursive: true));
  final bytes = Uint8List.fromList('RIFF....WEBPscoped-candidate'.codeUnits);

  test('targeted inspection and download retain unpinned cross-comic strong identity', () async {
    final trace = MemoryTraceSink();
    final service = await PersistentChapterDownloadService.open(root.path, traceSink: trace);
    addTearDown(service.close);
    final old = _entry('old', ['https://example.test/s/image-key/old']);
    final target = _entry('new', ['https://example.test/s/image-key/new']);
    final oldId = readerPageDownloadId(old.chapter.toManifest(), old.chapter.toManifest().pages.single);
    await service.storePromotedArtifact(id: oldId, bytes: bytes);
    expect((await service.artifactStore.index.get(oldId.key))!.pinned, isFalse);
    // Full inventory/repair may still read these rows. Targeted commands must
    // neither parse unrelated damaged metadata nor depend on its comic ID.
    final path = (service.artifactStore.index as SqliteIndex).path!;
    final db = sql.sqlite3.open(path);
    try {
      for (var i = 0; i < 200; i++) {
        db.execute('INSERT INTO cache_entry '
          '(key, download_json, state, path, bytes, checksum, created_us, touched_us, source_id, comic_id, chapter_id) '
          "VALUES (?, '{}', 'ready', ?, 1, 'unused', 1, 1, 'unrelated', 'unrelated', 'chapter')",
          ['unrelated-$i', '/unrelated/$i']);
      }
    } finally {
      db.close();
    }
    expect(await service.readyPageIndices(target), {0});
    final inspected = (await service.inspectMany([target])).single;
    expect(inspected.reusablePages, 1);
    expect(inspected.exactCompletedPages, 0);
    final projection = trace.events.lastWhere((event) =>
      event.payload['stage'] == 'targeted-projection-built');
    expect(projection.payload['indexedRecords'], 1);
    var network = 0;
    service.setChapterResourceAccess(ChapterResourceAccess(loadBytes: (_, __) async {
      network++;
      return bytes;
    }));
    await service.download(target);
    expect(network, 0);
    expect(await service.readPage(target, 0), bytes);
    expect((await service.inspect(target)).pinnedPages, 1);
    expect((await service.artifactStore.index.get(oldId.key))!.pinned, isFalse);
  });

  test('scoped opaque candidates retain proof gaps and relation revocation', () async {
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    final old = _entry('old', [for (var i = 0; i < 3; i++) 'venera-resource:old-$i']);
    final target = _entry('new', [for (var i = 0; i < 3; i++) 'venera-resource:new-$i']);
    final manifest = old.chapter.toManifest();
    for (final page in manifest.pages) {
      await service.storePromotedArtifact(id: readerPageDownloadId(manifest, page), bytes: bytes);
    }
    await service.artifactStore.index.putExportPageBindings([
      for (var i = 0; i < 3; i++) ExportPageBinding(sourceId: 'venera:test',
        comicId: 'old', chapterId: 'chapter', pageId: 'old-$i', logicalIndex: i,
        exportOrdinal: i + 1),
    ]);
    const relation = ComicVersionRelation(sourceId: 'venera:test',
      predecessorComicId: 'old', successorComicId: 'new', pageMappings: [
        ComicVersionPageMapping(predecessorChapterId: 'chapter',
          successorChapterId: 'chapter', predecessorPageCount: 3,
          successorPageCount: 3, successorOffset: 0,
          predecessorSourceRevision: 'r1', successorSourceRevision: 'r1',
          verifiedIntervals: [
            VerifiedComicVersionPageInterval(predecessorStart: 0,
              predecessorEndExclusive: 1, successorOffset: 0),
            VerifiedComicVersionPageInterval(predecessorStart: 2,
              predecessorEndExclusive: 3, successorOffset: 0),
          ]),
      ]);
    service.updateVersionBaselines([relation]);
    expect(await service.readyPageIndices(target), {0, 2});
    expect((await service.inspectMany([target])).single.reusablePages, 2);
    service.updateVersionBaselines([]);
    expect(await service.readyPageIndices(target), isEmpty);
    expect((await service.inspectMany([target])).single.reusablePages, 0);
  });
}

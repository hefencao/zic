import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/chapter_downloads.dart';

void main() {
  test('memory chapter download owns bytes before reporting completion', () async {
    final bytes = Uint8List.fromList(<int>[7, 8, 9]);
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:memory-comic',
        displayName: '第 1 话',
        sourceId: 'memory-source',
        comicId: 'memory-comic',
        comicTitle: '内存下载测试',
        chapterId: 'memory-chapter',
        sourceRevision: 'memory-r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.bin',
            sourceId: 'memory://page-1',
            pageId: 'memory-page-1',
            contentKindHint: ContentKindHint.unknown,
          ),
        ],
      ),
    );
    final service = MemoryChapterDownloadService(
      pageLoader: (_, __) async => bytes,
    );
    addTearDown(service.close);

    expect(await service.isDownloaded(entry), isFalse);
    await service.download(entry);
    expect(await service.isDownloaded(entry), isTrue);
    expect(await service.readPage(entry, 0), bytes);
  });

  test('persistent chapter download survives reopen and serves page bytes',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-chapter-download-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/source.bin');
    final bytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6]);
    await source.writeAsBytes(bytes, flush: true);
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:comic',
        displayName: '第 1 话',
        sourceId: 'fixture-source',
        comicId: 'fixture-comic',
        comicTitle: '离线下载测试',
        chapterId: 'fixture-chapter',
        sourceRevision: 'fixture-r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.bin',
            sourceId: source.uri.toString(),
            pageId: 'fixture-page-1',
            contentKindHint: ContentKindHint.unknown,
            byteLength: bytes.length,
          ),
        ],
      ),
    );

    final first = await PersistentChapterDownloadService.open(directory.path);
    expect(await first.isDownloaded(entry), isFalse);
    await first.download(entry);
    expect(await first.isDownloaded(entry), isTrue);
    expect(await first.readPage(entry, 0), bytes);
    await first.close();

    final reopened =
        await PersistentChapterDownloadService.open(directory.path);
    addTearDown(reopened.close);
    expect(await reopened.isDownloaded(entry), isTrue);
    expect(await reopened.readPage(entry, 0), bytes);
  });
}

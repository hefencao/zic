import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:test/test.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:downloads/downloads.dart';

void main() {
  test('page artifact tier reports, trims and clears independent resources',
      () async {
    final service = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(4),
    );
    addTearDown(service.close);
    final first = _entry('chapter-a');
    final second = _entry('chapter-b');

    await service.download(first);
    await service.download(second);
    expect(await service.inspectArtifacts(),
        isA<ArtifactCacheUsage>().having((usage) => usage.bytes, 'bytes', 8));

    final trimmed = await service.trimArtifacts(maxBytes: 6, targetBytes: 4);
    expect(trimmed.releasedBytes, 4);
    expect(trimmed.remainingBytes, 4);
    expect(trimmed.evictedEntries, 1);

    final cleared = await service.clearArtifacts();
    expect(cleared.releasedBytes, 4);
    expect(cleared.remainingBytes, 0);
    expect((await service.inspect(first)).phase, ChapterDownloadPhase.idle);
    expect((await service.inspect(second)).phase, ChapterDownloadPhase.idle);
  });

  test('partial chapter pages remain independently visible after trim', () async {
    final service = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(4),
    );
    addTearDown(service.close);
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:partial',
        displayName: 'partial',
        sourceId: 'cache-source',
        comicId: 'cache-comic',
        comicTitle: '缓存测试',
        chapterId: 'partial',
        sourceRevision: 'r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.bin',
            sourceId: 'memory://partial-1',
            pageId: 'partial-page-1',
            contentKindHint: ContentKindHint.unknown,
            byteLength: 4,
          ),
          ImportedPageRecord(
            displayName: '2.bin',
            sourceId: 'memory://partial-2',
            pageId: 'partial-page-2',
            contentKindHint: ContentKindHint.unknown,
            byteLength: 4,
          ),
        ],
      ),
    );

    await service.download(entry);
    final report = await service.trimArtifacts(maxBytes: 7, targetBytes: 4);
    expect(report.evictedEntries, 1);
    expect(report.remainingBytes, 4);

    final snapshot = await service.inspect(entry);
    expect(snapshot.phase, ChapterDownloadPhase.idle);
    expect(snapshot.completedPages, 1);
    expect(snapshot.receivedBytes, 4);
    expect(snapshot.hasDurableBytes, isTrue);
    expect(await service.isDownloaded(entry), isFalse);
  });
}

ImportedLibraryEntry _entry(String chapterId) => ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:$chapterId',
        displayName: chapterId,
        sourceId: 'cache-source',
        comicId: 'cache-comic',
        comicTitle: '缓存测试',
        chapterId: chapterId,
        sourceRevision: 'r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '$chapterId.bin',
            sourceId: 'memory://$chapterId',
            pageId: '$chapterId-page',
            contentKindHint: ContentKindHint.unknown,
            byteLength: 4,
          ),
        ],
      ),
    );

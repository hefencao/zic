import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/chapter_downloads.dart';

void main() {
  test('memory chapter cache reports, trims and clears completed chapters',
      () async {
    final service = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(4),
    );
    addTearDown(service.close);
    final first = _entry('chapter-a');
    final second = _entry('chapter-b');

    await service.download(first);
    await service.download(second);
    expect(await service.inspectCacheUsage(),
        isA<ChapterCacheUsage>().having((usage) => usage.bytes, 'bytes', 8));

    final trimmed = await service.trimCache(maxBytes: 6, targetBytes: 4);
    expect(trimmed.releasedBytes, 4);
    expect(trimmed.remainingBytes, 4);
    expect(trimmed.evictedEntries, 1);

    final cleared = await service.clearCache();
    expect(cleared.releasedBytes, 4);
    expect(cleared.remainingBytes, 0);
    expect((await service.inspect(first)).phase, ChapterDownloadPhase.idle);
    expect((await service.inspect(second)).phase, ChapterDownloadPhase.idle);
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

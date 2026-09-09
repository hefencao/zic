import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

void main() {
  test('reader page trace identity shares the exact DownloadId prefix', () {
    final chapter = ChapterManifest(
      sourceId: 'source',
      comicId: 'comic',
      chapter: const Chapter(
        chapterId: 'chapter',
        comicId: 'comic',
        title: 'Chapter',
        sequence: 1,
        pageCount: 1,
        sourceRevision: 'r2',
      ),
      pages: <PageAsset>[
        PageAsset(
          pageId: 'page-1',
          chapterId: 'chapter',
          index: 0,
          uri: Uri.parse('https://example.test/page-1.webp'),
        ),
      ],
      readingDirection: ReadingDirection.ltr,
    );
    final asset = chapter.pages.single;

    final download = readerPageDownloadId(chapter, asset);
    final trace = readerPageTraceIdentity(chapter, asset);

    expect(download.pageIndexHint, asset.index);
    expect(trace.pageAssetKey, asset.assetKey);
    expect(trace.resourceKeyPrefix, download.key);
    expect(trace.matchesResource(_event(download.key)), isTrue);
    expect(trace.matchesResource(_event('${download.key}|decode')), isTrue);
  });

  test('reader page identity rejects assets from another chapter', () {
    final chapter = ChapterManifest(
      sourceId: 'source',
      comicId: 'comic',
      chapter: const Chapter(
        chapterId: 'chapter',
        comicId: 'comic',
        title: 'Chapter',
        sequence: 1,
        pageCount: 1,
        sourceRevision: 'r2',
      ),
      pages: <PageAsset>[
        PageAsset(
          pageId: 'page-1',
          chapterId: 'chapter',
          index: 0,
          uri: Uri.parse('https://example.test/page-1.webp'),
        ),
      ],
      readingDirection: ReadingDirection.ltr,
    );
    final foreign = PageAsset(
      pageId: 'page-1',
      chapterId: 'other',
      index: 0,
      uri: Uri.parse('https://example.test/page-1.webp'),
    );

    expect(
      () => readerPageDownloadId(chapter, foreign),
      throwsArgumentError,
    );
  });
}

TraceEvent _event(String identity) => TraceEvent(
      monotonicMicros: 0,
      sessionId: 'reader',
      kind: TraceEventKind.decodeDemand,
      identityHash: identity,
    );

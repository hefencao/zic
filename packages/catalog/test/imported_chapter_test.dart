import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:test/test.dart';

void main() {
  test('folder record produces deterministic Reader identities', () {
    final first = ImportedChapterRecord.folder(
      directoryId: 'content://provider/tree/chapter',
      displayName: 'chapter',
      importedAt: DateTime.utc(2026, 7, 28),
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.webp',
          sourceId: 'content://provider/document/001',
          contentKindHint: ContentKindHint.webp,
          animatedHint: true,
        ),
        ImportedPageRecord(
          displayName: '002.png',
          sourceId: 'content://provider/document/002',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );
    final second = ImportedChapterRecord.folder(
      directoryId: 'content://provider/tree/chapter',
      displayName: 'renamed chapter',
      importedAt: DateTime.utc(2026, 7, 29),
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.webp',
          sourceId: 'content://provider/document/001',
          contentKindHint: ContentKindHint.webp,
          animatedHint: true,
        ),
        ImportedPageRecord(
          displayName: '002.png',
          sourceId: 'content://provider/document/002',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );

    expect(second.comicId, first.comicId);
    expect(second.chapterId, first.chapterId);
    expect(second.sourceRevision, first.sourceRevision);
    expect(first.coverSourceId, 'content://provider/document/001');
    final manifest = first.toManifest();
    expect(manifest.pages.map((page) => page.index), <int>[0, 1]);
    expect(
      manifest.pages.map((page) => page.pageId).toSet().length,
      manifest.pages.length,
    );
    expect(manifest.pages.first.pageId, first.pages.first.stablePageId);
    expect(manifest.pages.first.uri.toString(),
        'content://provider/document/001');
    expect(manifest.pages.first.contentKindHint, ContentKindHint.webp);
  });

  test('separate folder cover changes revision without changing work identity', () {
    const pages = <ImportedPageRecord>[
      ImportedPageRecord(
        displayName: '001.webp',
        sourceId: 'content://provider/document/001',
        contentKindHint: ContentKindHint.webp,
        animatedHint: true,
      ),
      ImportedPageRecord(
        displayName: '002.png',
        sourceId: 'content://provider/document/002',
        contentKindHint: ContentKindHint.png,
      ),
    ];
    final first = ImportedChapterRecord.folder(
      directoryId: 'content://provider/tree/chapter',
      displayName: 'chapter',
      coverSourceId: 'content://provider/document/cover-a',
      pages: pages,
    );
    final second = ImportedChapterRecord.folder(
      directoryId: 'content://provider/tree/chapter',
      displayName: 'chapter',
      coverSourceId: 'content://provider/document/cover-b',
      pages: pages,
    );

    expect(second.comicId, first.comicId);
    expect(second.chapterId, first.chapterId);
    expect(second.sourceRevision, isNot(first.sourceRevision));
    expect(first.coverSourceId, 'content://provider/document/cover-a');
    expect(second.coverSourceId, 'content://provider/document/cover-b');
  });

  test('stable page identity survives insertion before an existing page', () {
    final original = ImportedChapterRecord.folder(
      directoryId: '/chapter',
      displayName: 'chapter',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '2.png',
          sourceId: '/chapter/2.png',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );
    final refreshed = ImportedChapterRecord.folder(
      directoryId: '/chapter',
      displayName: 'chapter',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '1.png',
          sourceId: '/chapter/1.png',
          contentKindHint: ContentKindHint.png,
        ),
        ImportedPageRecord(
          displayName: '2.png',
          sourceId: '/chapter/2.png',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );

    expect(
      refreshed.toManifest().pages[1].pageId,
      original.toManifest().pages.single.pageId,
    );
  });

  test('folder revision changes with byte length and animation hints', () {
    ImportedChapterRecord record({
      required int byteLength,
      required bool animated,
    }) {
      return ImportedChapterRecord.folder(
        directoryId: '/chapter',
        displayName: 'chapter',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.webp',
            sourceId: '/chapter/1.webp',
            contentKindHint: ContentKindHint.webp,
            byteLength: byteLength,
            animatedHint: animated,
          ),
        ],
      );
    }

    final base = record(byteLength: 100, animated: false);
    expect(
      record(byteLength: 101, animated: false).sourceRevision,
      isNot(base.sourceRevision),
    );
    expect(
      record(byteLength: 100, animated: true).sourceRevision,
      isNot(base.sourceRevision),
    );
  });

  test('folder revision preserves exact imported media format', () {
    ImportedChapterRecord record(String mediaFormat) =>
        ImportedChapterRecord.folder(
          directoryId: '/chapter',
          displayName: 'chapter',
          pages: <ImportedPageRecord>[
            ImportedPageRecord(
              displayName: '1.data',
              sourceId: '/chapter/1.data',
              contentKindHint: ContentKindHint.fallback,
              mediaFormat: mediaFormat,
            ),
          ],
        );

    expect(record('bmp').sourceRevision, isNot(record('tiff').sourceRevision));
  });

  test('legacy cover metadata is recovered from its matching page', () {
    final json = ImportedChapterRecord.folder(
      directoryId: '/books/animated',
      displayName: 'animated',
      coverSourceId: '/books/animated/1.webp',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '1.webp',
          sourceId: '/books/animated/1.webp',
          contentKindHint: ContentKindHint.webp,
          mediaFormat: 'webp',
          animatedHint: true,
        ),
      ],
    ).toJson()
      ..remove('coverMediaFormat')
      ..remove('coverAnimatedHint');

    final restored = ImportedChapterRecord.fromJson(json);
    expect(restored.coverMediaFormat, 'webp');
    expect(restored.coverAnimatedHint, isTrue);
  });

  test('remote import preserves source checksum namespace through persistence', () {
    const comic = Comic(
      comicId: 'comic-1',
      sourceId: 'fixture',
      title: 'Fixture',
      authors: <String>[],
      readingDirection: ReadingDirection.ltr,
    );
    final manifest = ChapterManifest(
      sourceId: 'fixture',
      comicId: 'comic-1',
      chapter: const Chapter(
        chapterId: 'chapter-1',
        comicId: 'comic-1',
        title: 'Chapter',
        sequence: 1,
        pageCount: 1,
        sourceRevision: 'r1',
      ),
      pages: <PageAsset>[
        PageAsset(
          pageId: 'page-1',
          chapterId: 'chapter-1',
          index: 0,
          uri: Uri.parse('https://example.test/page.webp'),
          byteLength: 16,
          checksum: 'A1B2C3D4',
          checksumAlgorithm: 'CRC32',
          contentKindHint: ContentKindHint.webp,
        ),
      ],
      readingDirection: ReadingDirection.ltr,
    );

    final imported = ImportedChapterRecord.remote(
      comic: comic,
      manifest: manifest,
    );
    final restored = ImportedChapterRecord.fromJson(imported.toJson());
    final page = restored.toManifest().pages.single;

    expect(page.checksum, 'A1B2C3D4');
    expect(page.checksumAlgorithm, 'CRC32');
    expect(page.sourceChecksumForAlgorithm('crc32'), 'a1b2c3d4');
  });

  test('record JSON round trip preserves import metadata', () {
    final record = ImportedChapterRecord.folder(
      directoryId: '/books/chapter',
      displayName: 'chapter',
      importedAt: DateTime.utc(2026, 7, 28, 1, 2, 3),
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '1.jpg',
          sourceId: '/books/chapter/1.jpg',
          contentKindHint: ContentKindHint.jpeg,
          mediaFormat: 'jpeg',
          byteLength: 42,
        ),
      ],
    );

    final restored = ImportedChapterRecord.fromJson(record.toJson());
    expect(restored.toJson(), record.toJson());
    expect(restored.toManifest().chapter.pageCount, 1);
  });

  test('filesystem paths and content URIs keep distinct URI semantics', () {
    const windows = ImportedPageRecord(
      displayName: '001.webp',
      sourceId: r'C:\comics\chapter\001.webp',
      contentKindHint: ContentKindHint.webp,
    );
    const content = ImportedPageRecord(
      displayName: '002.webp',
      sourceId: 'content://provider/document/002',
      contentKindHint: ContentKindHint.webp,
    );

    expect(windows.uri.scheme, 'file');
    expect(
      windows.uri.toFilePath(windows: true),
      r'C:\comics\chapter\001.webp',
    );
    expect(content.uri.toString(), 'content://provider/document/002');
  });

  test('duplicate source identities keep distinct stable page identities', () {
    final record = ImportedChapterRecord.folder(
      directoryId: '/chapter',
      displayName: 'chapter',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '1.png',
          sourceId: '/chapter/1.png',
          pageId: 'page-1',
          contentKindHint: ContentKindHint.png,
        ),
        ImportedPageRecord(
          displayName: 'copy.png',
          sourceId: '/chapter/1.png',
          pageId: 'page-2',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );

    expect(record.pages.map((page) => page.sourceId).toSet(), hasLength(1));
    expect(
      record.pages.map((page) => page.pageId),
      <String?>['page-1', 'page-2'],
    );
  });

  test('duplicate source identities still require unique stable page ids', () {
    expect(
      () => ImportedChapterRecord.folder(
        directoryId: '/chapter',
        displayName: 'chapter',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.png',
            sourceId: '/chapter/1.png',
            contentKindHint: ContentKindHint.png,
          ),
          ImportedPageRecord(
            displayName: 'copy.png',
            sourceId: '/chapter/1.png',
            contentKindHint: ContentKindHint.png,
          ),
        ],
      ),
      throwsArgumentError,
    );
  });
}

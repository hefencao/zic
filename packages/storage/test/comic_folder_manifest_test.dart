import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  group('ComicFolderManifest & Directory Naming Tests', () {
    test('sanitizePathSegment cleans illegal characters and trims', () {
      expect(sanitizePathSegment('航海王: 剧场版/特别篇 * ? " < > |'), '航海王_ 剧场版_特别篇 _ _ _ _ _ _');
      expect(sanitizePathSegment('...test...'), 'test');
      expect(sanitizePathSegment('   '), 'untitled');
      expect(sanitizePathSegment('', fallback: 'default_name'), 'default_name');
    });

    test('buildComicDirectoryName creates clean or suffixed comic folder names', () {
      expect(
        buildComicDirectoryName(comicTitle: '航海王: 红发歌姬'),
        '航海王_ 红发歌姬',
      );
      expect(
        buildComicDirectoryName(
          comicTitle: '航海王',
          conflictSourceSuffix: '拷贝漫画',
        ),
        '航海王 (拷贝漫画)',
      );
      expect(
        buildComicDirectoryName(
          comicTitle: '航海王',
          conflictSourceSuffix: '',
        ),
        '航海王',
      );
    });

    test('buildChapterDirectoryName creates clean chapter names', () {
      expect(
        buildChapterDirectoryName('第01话: 冒险的黎明/初阵'),
        '第01话_ 冒险的黎明_初阵',
      );
      expect(
        buildChapterDirectoryName('', fallbackIndex: 5),
        'chapter_5',
      );
    });

    test('buildPageFileName formats zero-padded page and sanitized extension', () {
      expect(
        buildPageFileName(pageIndex: 1, extension: '.webp'),
        '001.webp',
      );
      expect(
        buildPageFileName(pageIndex: 42, extension: 'JPG'),
        '042.jpg',
      );
      expect(
        buildPageFileName(pageIndex: 999, extension: 'png'),
        '999.png',
      );
    });

    test('hasSourceSuffixInFolderName detects existing source suffix to avoid UI duplication', () {
      expect(
        hasSourceSuffixInFolderName('航海王 (拷贝漫画)', '拷贝漫画'),
        isTrue,
      );
      expect(
        hasSourceSuffixInFolderName('航海王 (copymanga)', 'copymanga'),
        isTrue,
      );
      expect(
        hasSourceSuffixInFolderName('航海王', '拷贝漫画'),
        isFalse,
      );
      expect(
        hasSourceSuffixInFolderName('航海王 (动漫之家)', '拷贝漫画'),
        isFalse,
      );
    });

    test('buildPageRelativePath handles single chapter vs multi-chapter', () {
      expect(
        buildPageRelativePath(
          comicTitle: '图集A',
          chapterTitle: '第 1 话',
          pageIndex: 1,
          extension: 'webp',
          isSingleChapter: true,
        ),
        '图集A/001.webp',
      );
      expect(
        buildPageRelativePath(
          comicTitle: '长篇漫画B',
          chapterTitle: '第 1 话',
          sequence: 1,
          pageIndex: 1,
          extension: 'webp',
          isSingleChapter: false,
        ),
        '长篇漫画B/第 1 话/001.webp',
      );
    });

    test('ComicFolderManifest serializes and deserializes correctly', () {
      final now = DateTime.utc(2026, 8, 27, 23, 30, 0);
      final manifest = ComicFolderManifest(
        sourceId: 'copymanga',
        sourceDisplayName: '拷贝漫画',
        comicId: 'one_piece',
        comicTitle: '航海王',
        chapters: const <String>['ch-1', 'ch-2'],
        updatedAt: now,
      );

      final encoded = manifest.encode();
      final decoded = ComicFolderManifest.decode(encoded);

      expect(decoded, isNotNull);
      expect(decoded!.format, comicManifestFormatV1);
      expect(decoded.sourceId, 'copymanga');
      expect(decoded.sourceDisplayName, '拷贝漫画');
      expect(decoded.comicId, 'one_piece');
      expect(decoded.comicTitle, '航海王');
      expect(decoded.chapters, <String>['ch-1', 'ch-2']);
      expect(decoded.isSingleChapter, isFalse);
      expect(decoded.updatedAt, now);
    });

    test('manifest fingerprint is independent of nested map insertion order', () {
      final first = ComicFolderManifest(
        sourceId: 'source',
        comicId: 'comic',
        comicTitle: 'title',
        chapterDirectories: const <String, String>{
          'chapter-b': 'B',
          'chapter-a': 'A',
        },
        chapterTitles: const <String, String>{
          'chapter-b': 'Title B',
          'chapter-a': 'Title A',
        },
        updatedAt: DateTime.utc(2026, 8, 27),
      );
      final second = ComicFolderManifest(
        sourceId: 'source',
        comicId: 'comic',
        comicTitle: 'title',
        chapterDirectories: const <String, String>{
          'chapter-a': 'A',
          'chapter-b': 'B',
        },
        chapterTitles: const <String, String>{
          'chapter-a': 'Title A',
          'chapter-b': 'Title B',
        },
        updatedAt: DateTime.utc(2026, 8, 27),
      );

      expect(first.computedFingerprint, second.computedFingerprint);
      expect(
        ComicFolderManifest(
          sourceId: second.sourceId,
          comicId: second.comicId,
          comicTitle: second.comicTitle,
          chapterDirectories: second.chapterDirectories,
          chapterTitles: second.chapterTitles,
          fingerprint: first.computedFingerprint,
          updatedAt: second.updatedAt,
        ).fingerprintValid,
        isTrue,
      );
    });

    test('parsePageIndexFromFileName parses various page file conventions', () {
      expect(parsePageIndexFromFileName('001.webp'), 1);
      expect(parsePageIndexFromFileName('008.webp'), 8);
      expect(parsePageIndexFromFileName('12.jpg'), 12);
      expect(parsePageIndexFromFileName('page_05.png'), 5);
      expect(parsePageIndexFromFileName('p3.avif'), 3);
      expect(parsePageIndexFromFileName('001_thumb.webp'), 1);
      expect(parsePageIndexFromFileName('001 (1).webp'), 1);
      expect(parsePageIndexFromFileName('.zic.json'), isNull);
      expect(parsePageIndexFromFileName('cache.sqlite'), isNull);
      expect(parsePageIndexFromFileName('manifest.json'), isNull);
    });
  });
}

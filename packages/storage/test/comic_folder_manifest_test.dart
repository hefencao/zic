import 'dart:convert';

import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  group('ComicFolderManifest & Directory Naming Tests', () {
    test('legacy v1 and v2 fingerprints remain readable unchanged', () {
      final json = jsonDecode('{"format":"zic-comic-v2","sourceId":"source",'
        '"comicId":"comic","comicTitle":"Title","chapters":["chapter"],'
        '"chapterTitles":{"chapter":"Chapter"},"chapterSequences":{"chapter":1},'
        '"chapterFiles":{"chapter":{"sourceRevision":"r1","pageCount":1,'
        '"pages":[{"index":0,"pageId":"page","file":"001.png","bytes":3,'
        '"checksum":"12345678","checksumAlgorithm":"crc32"}]}},'
        '"generation":0,"fingerprint":"92d609f5","updatedAt":"2026-01-01T00:00:00.000Z"}')
        as Map<String, dynamic>;
      for (final version in ['v2', 'v1']) {
        if (version == 'v1') {
          json['format'] = 'zic-comic-v1';
          json['fingerprint'] = '1b4366b4';
          json.remove('chapterFiles');
        }
        final decoded = ComicFolderManifest.decode(jsonEncode(json))!;
        expect(decoded.fingerprintValid, isTrue);
        expect(decoded.computedFingerprint, json['fingerprint']);
        expect(decoded.toJson(), json);
      }
    });

    test('compact chapters preserve order, mixed algorithms and no-op commits', () async {
      final id = 'chapter-'.padRight(254, 'x');
      final draft = ComicFolderManifest(format: 'zic-comic-v3',
        sourceId: 'source', comicId: 'comic', comicTitle: 'Comic',
        chapters: [id, 'another'], chapterDirectories: {id: 'First'},
        chapterTitles: {id: 'Title'}, chapterSequences: {id: 7},
        updatedAt: DateTime.utc(2026), chapterFiles: {
          id: const ComicChapterFileList(sourceRevision: 'r1', pageCount: 3,
            pages: [ComicPageFile(logicalIndex: 0, pageId: 'first',
              fileName: '002.png', bytes: 3, checksum: '12345678', checksumAlgorithm: 'crc32'),
              ComicPageFile(logicalIndex: 2, pageId: 'last', fileName: '001.png',
                bytes: 4, checksum: 'abcdef', checksumAlgorithm: 'sha256')]),
        });
      final prepared = await prepareComicFolderManifestAsync(draft);
      final raw = jsonDecode(prepared.encoded) as Map;
      expect(raw['chapters'], isA<Map>());
      expect(prepared.encoded.split(id), hasLength(2));
      expect(raw.keys, isNot(contains('chapterDirectories')));
      final entries = (raw['chapters'] as Map)['entries'] as List;
      final files = (entries.first as Map)['files'] as Map;
      expect(files['checksumAlgorithm'], 'crc32');
      expect((files['pages'] as List).first, isNot(contains('checksumAlgorithm')));
      expect(((files['pages'] as List).last as Map)['checksumAlgorithm'], 'sha256');
      final decoded = ComicFolderManifest.decode(prepared.encoded)!;
      expect(decoded.fingerprintValid, isTrue);
      expect(decoded.chapters, [id, 'another']);
      expect(decoded.chapterDirectories, {id: 'First'});
      expect(decoded.chapterTitles, {id: 'Title'});
      expect(decoded.chapterSequences, {id: 7});
      expect(decoded.chapterFiles[id]!.pageCount, 3);
      expect(decoded.chapterFiles[id]!.pages.map((p) => p.logicalIndex), [0, 2]);
      expect(decoded.toJson(), raw);
      expect(await prepareComicFolderManifestUpdateAsync(draft.copyWith(
        generation: 4, updatedAt: DateTime.utc(2027)), decoded), isNull);
      entries.removeLast();
      final tampered = ComicFolderManifest.decode(jsonEncode(raw))!;
      expect(tampered.fingerprintValid, isFalse);
    });

    test('compact chapters reject duplicate identity and ambiguous algorithms', () async {
      final draft = ComicFolderManifest(format: 'zic-comic-v3',
        sourceId: 'source', comicId: 'comic', comicTitle: 'Comic',
        chapters: ['chapter'], updatedAt: DateTime.utc(2026),
        chapterFiles: {'chapter': const ComicChapterFileList(
          sourceRevision: 'r1', pageCount: 1, pages: [ComicPageFile(
            logicalIndex: 0, pageId: 'page', fileName: '001.png', bytes: 3,
            checksum: '12345678', checksumAlgorithm: 'crc32')])});
      final prepared = await prepareComicFolderManifestAsync(draft);
      Map firstFiles(Map raw) => (((raw['chapters'] as Map)['entries'] as List)
        .first as Map)['files'] as Map;
      for (final mutation in <void Function(Map)>[
        (duplicate) {
          final entries = (duplicate['chapters'] as Map)['entries'] as List;
          entries.add(entries.first);
        },
        (conflicting) => conflicting['chapterTitles'] = {'chapter': 'Conflicting metadata'},
        (missingAlgorithm) => firstFiles(missingAlgorithm)['checksumAlgorithm'] = null,
        (emptyAlgorithm) => ((firstFiles(emptyAlgorithm)['pages'] as List).first as Map)
          ['checksumAlgorithm'] = '',
      ]) {
        final raw = jsonDecode(prepared.encoded) as Map;
        mutation(raw);
        expect(ComicFolderManifest.decode(jsonEncode(raw)), isNull);
      }
    });

    test('unchanged portable content skips a generation and page changes do not', () async {
      final draft = ComicFolderManifest(format: comicManifestFormatV2,
        sourceId: 'source', comicId: 'comic', comicTitle: 'Comic',
        chapters: ['chapter'], updatedAt: DateTime.utc(2026),
        chapterFiles: {'chapter': const ComicChapterFileList(
          sourceRevision: 'r1', pageCount: 1, pages: [ComicPageFile(
            logicalIndex: 0, pageId: 'page', fileName: '001.png', bytes: 3,
            checksum: '12345678', checksumAlgorithm: 'crc32')])});
      final original = (await prepareComicFolderManifestAsync(draft)).manifest;
      final next = draft.copyWith(generation: 2, updatedAt: DateTime.utc(2027));
      expect(await prepareComicFolderManifestUpdateAsync(next, original), isNull);
      final changed = await prepareComicFolderManifestUpdateAsync(next.copyWith(
        chapterFiles: {'chapter': const ComicChapterFileList(
          sourceRevision: 'r1', pageCount: 1, pages: [ComicPageFile(
            logicalIndex: 0, pageId: 'changed', fileName: '001.png', bytes: 3,
            checksum: '12345678', checksumAlgorithm: 'crc32')])}), original);
      expect(changed!.manifest.generation, 2);
      expect(changed.manifest.fingerprintValid, isTrue);
      expect(ComicFolderManifest.decode(changed.encoded)!.chapterFiles['chapter']!
          .pages.single.pageId, 'changed');
    });

    test('owned manifests round-trip beyond external scan entry budgets', () async {
      for (final chapterCount in [1, comicManifestMaxEntries + 1]) {
        final ids = [for (var i = 0; i < chapterCount; i++) 'chapter-$i'];
        final prepared = await prepareComicFolderManifestAsync(ComicFolderManifest(
          format: comicManifestFormatV3, sourceId: 'source', comicId: 'comic',
          comicTitle: 'Comic', chapters: ids, updatedAt: DateTime.utc(2026),
          chapterFiles: {ids.first: ComicChapterFileList(
            sourceRevision: 'r1', pageCount: comicManifestMaxEntries + 1, pages: [
              if (chapterCount == 1)
                for (var i = 0; i <= comicManifestMaxEntries; i++) ComicPageFile(
                  logicalIndex: i, pageId: 'page-$i', fileName: '$i.png', bytes: 3,
                  checksum: '12345678', checksumAlgorithm: 'crc32'),
            ])}));
        final decoded = ComicFolderManifest.decode(prepared.encoded)!;
        expect(decoded.fingerprintValid, isTrue);
        expect(decoded.chapters, ids);
        expect(decoded.chapterFiles[ids.first]!.pageCount, comicManifestMaxEntries + 1);
        expect(decoded.chapterFiles[ids.first]!.pages,
          hasLength(chapterCount == 1 ? comicManifestMaxEntries + 1 : 0));
      }
    });

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

import 'dart:io';
import 'dart:typed_data';

import 'package:bridge/bridge.dart' show parseWebpInfo;
import 'package:domain/domain.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/static_demo.dart';
import 'package:zic/webp_demo.dart';

File _nativeFixture(String name) {
  final candidates = <File>[
    File('native/media_core/testdata/$name'),
    File('../../native/media_core/testdata/$name'),
  ];
  return candidates.firstWhere(
    (file) => file.existsSync(),
    orElse: () => throw StateError('Missing native fixture: $name'),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled Animated WebP index contains the native fixtures', () async {
    final entries = await loadWebpDemoEntries();

    expect(entries, hasLength(3));
    expect(entries.map((entry) => entry.asset).toList(), <String>[
      'assets/demo/animated/animated.webp',
      'assets/demo/animated/finite_loop.webp',
      'assets/demo/animated/partial_blend.webp',
    ]);
    expect(entries.map((entry) => entry.frameCount).toList(), everyElement(2));
  });

  test('PickedWebp owns its explicit display-name contract', () {
    final picked = PickedWebp(
      file: XFile('/virtual/source-with-unrelated-name'),
      displayName: ' local.webp ',
    );
    final screen = WebpPlayerScreen.picked(picked);

    expect(picked.displayName, 'local.webp');
    expect(screen.title, 'local.webp');
    expect(screen.sourceUri.path, '/virtual/source-with-unrelated-name');
  });

  test('system picker wraps the selected file', () async {
    final file = XFile('/tmp/imported/selected.webp');

    final picked = await pickLocalWebp(selectFile: () async => file);

    expect(picked, isNotNull);
    expect(picked!.file, same(file));
    expect(picked.displayName, 'selected.webp');
  });

  test('Reader media identity matches the chapter manifest contract', () {
    final asset = PageAsset(
      pageId: 'page',
      chapterId: 'chapter',
      index: 0,
      uri: Uri.parse('asset:///page.webp'),
      contentKindHint: ContentKindHint.webp,
    );
    final chapter = ChapterManifest(
      sourceId: 'source',
      comicId: 'comic',
      chapter: const Chapter(
        chapterId: 'chapter',
        comicId: 'comic',
        title: 'Chapter',
        sequence: 1,
        pageCount: 1,
        sourceRevision: 'revision',
      ),
      pages: <PageAsset>[asset],
      readingDirection: ReadingDirection.ltr,
    );

    final download = readerPageDownloadId(chapter, asset);

    expect(download.content.sourceId, 'source');
    expect(download.content.comicId, 'comic');
    expect(download.content.chapterId, 'chapter');
    expect(download.content.pageId, 'page');
    expect(download.sourceRevision, 'revision');
    expect(download.canonicalUri, asset.uri);
  });

  test('Reader media player owns the supplied download identity', () {
    final download = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'revision',
      canonicalUri: Uri.parse('asset:///page.webp'),
    );
    final player = NativeWebpPlayer(
      title: 'page',
      sourceUri: download.canonicalUri,
      loadBytes: (_) async => Uint8List(0),
      downloadIdentity: download,
    );

    expect(player.downloadIdentity, same(download));
  });

  test('scoped folder picker preserves content URI byte access', () async {
    final bytes = Uint8List.fromList(<int>[
      ...'RIFF'.codeUnits,
      4,
      0,
      0,
      0,
      ...'WEBP'.codeUnits,
    ]);
    var reads = 0;
    final folder = await pickLocalImageFolder(
      pickDirectoryContents: () async => LocalImageDirectorySelection(
        directoryId: 'content://provider/tree/chapter',
        displayName: 'chapter',
        scan: LocalImageDirectoryScan(
          images: <LocalImageFile>[
            LocalImageFile(
              file: XFile('content://provider/document/page-1'),
              format: LocalImageFormat.webp,
              displayName: 'sub/001.webp',
              sourceId: 'content://provider/document/page-1',
              readBytes: () async {
                reads++;
                return bytes;
              },
            ),
          ],
          scannedFiles: 1,
          unreadableFiles: 0,
        ),
      ),
    );

    expect(folder, isNotNull);
    expect(folder!.directoryPath, 'content://provider/tree/chapter');
    expect(folder.displayName, 'chapter');
    expect(folder.files.single.displayName, 'sub/001.webp');
    expect(
      folder.files.single.sourceUri.toString(),
      'content://provider/document/page-1',
    );
    expect(await folder.files.single.readAsBytes(), bytes);
    expect(reads, 1);
  });

  test('folder picker preserves cancellation as null', () async {
    final picked = await pickLocalImageFolder(
      selectDirectory: () async => null,
      listFiles: (_) async => throw StateError('must not enumerate'),
    );

    expect(picked, isNull);
  });

  test(
    'folder picker owns relative display names independently of XFile.name',
    () async {
      final first = XFile('/library/chapter/001.data');
      final nested = XFile('/library/chapter/sub/002.bin');

      final folder = await pickLocalImageFolder(
        selectDirectory: () async => '/library/chapter',
        listFiles: (_) async => LocalImageDirectoryScan(
          images: <LocalImageFile>[
            LocalImageFile(file: first, format: LocalImageFormat.webp),
            LocalImageFile(file: nested, format: LocalImageFormat.png),
          ],
          scannedFiles: 3,
          unreadableFiles: 1,
        ),
      );

      expect(folder, isNotNull);
      expect(folder!.displayName, 'chapter');
      expect(folder.files.map((file) => file.displayName), <String>[
        '001.data',
        'sub/002.bin',
      ]);
      expect(folder.files.map((file) => file.format), <LocalImageFormat>[
        LocalImageFormat.webp,
        LocalImageFormat.png,
      ]);
      expect(folder.files[0].file, same(first));
      expect(folder.files[1].file, same(nested));
      expect(folder.scannedFiles, 3);
      expect(folder.unreadableFiles, 1);
    },
  );

  test('folder picker rejects a directory without recognized images', () async {
    await expectLater(
      pickLocalImageFolder(
        selectDirectory: () async => '/library/empty',
        listFiles: (_) async => LocalImageDirectoryScan(
          images: const <LocalImageFile>[],
          scannedFiles: 7,
          unreadableFiles: 2,
        ),
      ),
      throwsA(
        isA<FormatException>()
            .having(
              (error) => error.message,
              'message',
              contains('没有可识别的图片'),
            )
            .having(
              (error) => error.message,
              'scan count',
              contains('7 个文件'),
            )
            .having(
              (error) => error.message,
              'unreadable count',
              contains('2 个文件不可读取'),
            ),
      ),
    );
  });

  test('system picker preserves cancellation as null', () async {
    final picked = await pickLocalWebp(selectFile: () async => null);

    expect(picked, isNull);
  });

  test('valid local WebP passes container validation', () {
    final bytes = _nativeFixture('finite_loop.webp').readAsBytesSync();

    final info = parseWebpInfo(bytes);

    expect(info.width, greaterThan(0));
    expect(info.height, greaterThan(0));
  });

  test('malformed local WebP fails container validation', () {
    final bytes = Uint8List.fromList(<int>[
      0x52,
      0x49,
      0x46,
      0x46,
      0,
      0,
      0,
      0,
      0x57,
      0x45,
      0x42,
      0x50,
    ]);

    expect(() => parseWebpInfo(bytes), throwsFormatException);
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_media/local_media.dart';

void main() {
  test(
    'directory loader recognizes image headers independent of filename',
    () async {
      final root = await Directory.systemTemp.createTemp('zic-image-folder-');
      addTearDown(() => root.delete(recursive: true));

      await File('${root.path}/10.txt').writeAsBytes(<int>[
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
        0,
        0,
        0,
        13,
        ...'IHDR'.codeUnits,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        1,
      ]);
      await File('${root.path}/2.data').writeAsBytes(
        base64Decode(
          'UklGRoQAAABXRUJQVlA4WAoAAAACAAAAAQAAAQAAQU5JTQYAAAAAAAAAAgBB'
          'Tk1GKAAAAAAAAAAAAAEAAAEAADwAAAJWUDhMDwAAAC8BQAAABxD9j/4HIqL/'
          'AQBBTk1GKAAAAAAAAAAAAAEAAAEAAFoAAABWUDhMDwAAAC8BQAAAB9D/iP4H'
          'IqL/AQA=',
        ),
      );
      await File('${root.path}/fake.png').writeAsString('not an image');
      final nested = Directory('${root.path}/nested');
      await nested.create();
      await File('${nested.path}/1').writeAsBytes(
        <int>[0xff, 0xd8, 0xff, 0xe0],
      );

      final scan = await listLocalImageDirectory(root.path);
      final normalized = scan.images
          .map(
            (image) => (
              image.file.path.replaceAll('\\', '/'),
              image.format,
            ),
          )
          .toList(growable: false);
      final normalizedRoot = root.path.replaceAll('\\', '/');

      expect(normalized, <(String, LocalImageFormat)>[
        ('$normalizedRoot/2.data', LocalImageFormat.webp),
        ('$normalizedRoot/10.txt', LocalImageFormat.png),
        ('$normalizedRoot/nested/1', LocalImageFormat.jpeg),
      ]);
      expect(scan.scannedFiles, 4);
      expect(scan.unreadableFiles, 0);
      expect(scan.unrecognizedFiles, 1);
    },
  );

  test('directory loader does not trust an image-looking extension', () async {
    final root = await Directory.systemTemp.createTemp('zic-image-empty-');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/fake.webp').writeAsString('plain text');
    await File('${root.path}/notes.jpg').writeAsString('plain text');

    final scan = await listLocalImageDirectory(root.path);

    expect(scan.images, isEmpty);
    expect(scan.scannedFiles, 2);
    expect(scan.unrecognizedFiles, 2);
  });

  test('directory loader rejects a missing directory', () async {
    final missing = '${Directory.systemTemp.path}/zic-missing-folder-test';

    await expectLater(
      listLocalImageDirectory(missing),
      throwsA(isA<FileSystemException>()),
    );
  });

  test(
    'directory loader rejects a content URI instead of reporting no images',
    () async {
      await expectLater(
        listLocalImageDirectory('content://com.example.provider/tree/chapter'),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.message,
            'message',
            contains('content URI'),
          ),
        ),
      );
    },
  );
}

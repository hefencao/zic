import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_media/local_media.dart';

void main() {
  test('directory loader recognizes image headers independent of filename',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-image-folder-');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/10.txt').writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
    await File('${root.path}/2.data').writeAsBytes(
      base64Decode(
        'UklGRoQAAABXRUJQVlA4WAoAAAACAAAAAQAAAQAAQU5JTQYAAAAAAAAAAgBB'
        'Tk1GKAAAAAAAAAAAAAEAAAEAADwAAAJWUDhMDwAAAC8BQAAABxD9j/4HIqL/'
        'AQBBTk1GKAAAAAAAAAAAAAEAAAEAAFoAAABWUDhMDwAAAC8BQAAAB9D/iP4H'
        'IqL/AQA=',
      ),
    );
    final nested = Directory('${root.path}/nested');
    await nested.create();
    await File('${nested.path}/1').writeAsBytes(
      <int>[0xff, 0xd8, 0xff, 0xe0],
    );

    final scan = await listLocalImageDirectory(root.path);
    expect(
      scan.images.map((image) => image.format),
      <LocalImageFormat>[
        LocalImageFormat.webp,
        LocalImageFormat.png,
        LocalImageFormat.jpeg,
      ],
    );
  });
}

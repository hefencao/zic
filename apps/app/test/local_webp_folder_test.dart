import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zic/local_webp_folder.dart';

void main() {
  test(
    'directory loader recursively filters and naturally orders WebP files',
    () async {
      final root = await Directory.systemTemp.createTemp('zic-webp-folder-');
      addTearDown(() => root.delete(recursive: true));

      await File('${root.path}/10.webp').writeAsBytes(<int>[10]);
      await File('${root.path}/2.WEBP').writeAsBytes(<int>[2]);
      await File('${root.path}/ignore.png').writeAsBytes(<int>[0]);
      final nested = Directory('${root.path}/nested');
      await nested.create();
      await File('${nested.path}/1.webp').writeAsBytes(<int>[1]);

      final files = await listLocalWebpDirectory(root.path);
      final normalized = files
          .map((file) => file.path.replaceAll('\\', '/'))
          .toList(growable: false);
      final normalizedRoot = root.path.replaceAll('\\', '/');

      expect(normalized, <String>[
        '$normalizedRoot/2.WEBP',
        '$normalizedRoot/10.webp',
        '$normalizedRoot/nested/1.webp',
      ]);
    },
  );

  test('directory loader rejects a missing directory', () async {
    final missing = '${Directory.systemTemp.path}/zic-missing-folder-test';

    await expectLater(
      listLocalWebpDirectory(missing),
      throwsA(isA<FileSystemException>()),
    );
  });
}

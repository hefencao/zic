import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:storage_bridge/storage_bridge.dart';

void main() {
  test('default imported library factory is exposed', () {
    expect(openDefaultImportedLibraryStore, isA<Function>());
  });

  test('storage root can use the lightweight platform path boundary', () async {
    final root = await getDefaultZicStorageRoot(
      applicationSupportPath: () async => '/data/user/0/dev.zic/files',
    );
    expect(root, '/data/user/0/dev.zic/files/zic');
  });

  test('fresh installs do not report durable application state', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-storage-state-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    expect(await durableZicStateExists(directory.path), isFalse);
    await File('${directory.path}/whole_comic_queue.json').writeAsString('{}');
    expect(await durableZicStateExists(directory.path), isTrue);
  });

  test('a Home snapshot short-circuits the durable state probe', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-storage-snapshot-state-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    await File('${directory.path}/home_projection_snapshot.json')
        .writeAsString('{}');
    expect(await durableZicStateExists(directory.path), isTrue);
  });
}

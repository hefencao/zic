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

  test('directory recovery propagates a failed move for retry handling',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-storage-move-recovery-',
    );
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final separator = Platform.pathSeparator;
    final source = Directory('${root.path}${separator}source');
    final target = Directory('${root.path}${separator}target');
    await Directory('${source.path}${separator}final').create(recursive: true);
    await Directory('${target.path}${separator}final').create(recursive: true);
    await File('${source.path}${separator}final${separator}page.bin')
        .writeAsBytes(const <int>[1]);
    await File('${target.path}${separator}final${separator}page.bin')
        .writeAsBytes(const <int>[2]);

    await expectLater(
      settleChapterDownloadDirectory(
        storageRoot: root.path,
        configuredOverride: target.path,
        pendingMoveFrom: source.path,
      ),
      throwsStateError,
    );
  });

  test('default-location recovery propagates a failed move for retry handling',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-storage-default-move-recovery-',
    );
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final source = Directory(
      '${root.path}${Platform.pathSeparator}offline_chapters',
    );
    final target = Directory('${root.path}${Platform.pathSeparator}target');
    await Directory('${source.path}${Platform.pathSeparator}final')
        .create(recursive: true);
    await Directory('${target.path}${Platform.pathSeparator}final')
        .create(recursive: true);
    await File('${source.path}${Platform.pathSeparator}final${Platform.pathSeparator}page.bin')
        .writeAsBytes(const <int>[1]);
    await File('${target.path}${Platform.pathSeparator}final${Platform.pathSeparator}page.bin')
        .writeAsBytes(const <int>[2]);

    await expectLater(
      settleChapterDownloadDirectory(
        storageRoot: root.path,
        configuredOverride: target.path,
      ),
      throwsStateError,
    );
  });

  test('App-private chapter metadata alone is durable application state',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-storage-private-metadata-state-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    await File(defaultChapterDownloadMetadataPath(root.path))
        .writeAsBytes(const <int>[1]);

    expect(await durableZicStateExists(root.path), isTrue);
  });

  test('private metadata disables legacy default-root auto adoption', () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-storage-private-root-authority-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final defaultDirectory = Directory(
      defaultChapterDownloadDirectory(root.path),
    );
    final target = Directory(
      '${root.path}${Platform.pathSeparator}custom',
    );
    final oldPage = File(
      '${defaultDirectory.path}${Platform.pathSeparator}final'
      '${Platform.pathSeparator}old.bin',
    );
    await oldPage.parent.create(recursive: true);
    await oldPage.writeAsBytes(const <int>[1]);
    await target.create(recursive: true);
    final metadataPath = defaultChapterDownloadMetadataPath(root.path);
    await File(metadataPath).writeAsBytes(const <int>[1]);

    expect(
      await settleChapterDownloadDirectory(
        storageRoot: root.path,
        configuredOverride: target.path,
        metadataDbPath: metadataPath,
      ),
      target.path,
    );
    expect(await oldPage.exists(), isTrue);
  });

  test('SAF selection never treats the default byte store as a POSIX move source',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-storage-saf-settle-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final defaultDirectory = Directory(
      defaultChapterDownloadDirectory(root.path),
    );
    final retained = File(
      '${defaultDirectory.path}${Platform.pathSeparator}final'
      '${Platform.pathSeparator}page.bin',
    );
    await retained.parent.create(recursive: true);
    await retained.writeAsBytes(const <int>[1, 2, 3]);
    const safTarget =
        'saf://content://com.android.externalstorage.documents/tree/primary%3ABooks';

    expect(
      await settleChapterDownloadDirectory(
        storageRoot: root.path,
        configuredOverride: safTarget,
      ),
      safTarget,
    );
    expect(await retained.exists(), isTrue);
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

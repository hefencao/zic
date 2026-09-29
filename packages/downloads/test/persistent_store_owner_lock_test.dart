import 'dart:io';

import 'package:downloads/downloads.dart';
import 'package:test/test.dart';

void main() {
  test('same process cannot own one metadata index through two byte roots',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-persistent-owner-same-process-',
    );
    addTearDown(() => root.delete(recursive: true));
    final indexPath = '${root.path}/chapter_downloads.sqlite';
    final first = await PersistentDownloadArtifactStore.open(
      root.path,
      directory: '${root.path}/first',
      indexPath: indexPath,
    );
    var firstClosed = false;
    addTearDown(() async {
      if (!firstClosed) await first.close();
    });

    await expectLater(
      PersistentDownloadArtifactStore.open(
        root.path,
        directory: '${root.path}/second',
        indexPath: indexPath,
      ),
      throwsA(isA<StateError>()),
    );

    await first.close();
    firstClosed = true;
    final second = await PersistentDownloadArtifactStore.open(
      root.path,
      directory: '${root.path}/second',
      indexPath: indexPath,
    );
    await second.close();
  });

  test('persistent metadata owner lock excludes another process until close',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-persistent-owner-lock-',
    );
    addTearDown(() => root.delete(recursive: true));
    final indexPath = '${root.path}/chapter_downloads.sqlite';
    final lockPath = '$indexPath.owner.lock';
    final probe = File(
      'test/fixtures/metadata_owner_lock_probe.dart',
    ).absolute;


    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      indexPath: indexPath,
    );
    var closed = false;
    addTearDown(() async {
      if (!closed) await store.close();
    });

    final whileOpen = await Process.run(
      Platform.resolvedExecutable,
      <String>[probe.path, lockPath],
    );
    expect(whileOpen.exitCode, 0);
    expect('${whileOpen.stdout}', 'blocked',
        reason: 'a live metadata owner must reject another process');

    await store.close();
    closed = true;

    final afterClose = await Process.run(
      Platform.resolvedExecutable,
      <String>[probe.path, lockPath],
    );
    expect(afterClose.exitCode, 0);
    expect('${afterClose.stdout}', 'acquired',
        reason: 'clean close must release the process owner lock');
  });
}

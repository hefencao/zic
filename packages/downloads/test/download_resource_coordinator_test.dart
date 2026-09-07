import 'dart:io';

import 'package:downloads/downloads.dart';
import 'package:test/test.dart';

void main() {
  test('storage writes use a distinct capacity domain tied to local-read pressure', () async {
    final resources = DownloadResourceCoordinator();

    expect(
      identical(
        resources.storageWriteScheduler.localReadScheduler,
        resources.localReadScheduler,
      ),
      isTrue,
    );
    expect(resources.storageWriteScheduler.activeCount, 0);

    final pressure = resources.localReadScheduler.holdForegroundPressure();
    var acquired = false;
    final pending = resources.storageWriteScheduler.acquireQuantum().then((lease) {
      acquired = true;
      return lease;
    });
    await Future<void>.delayed(Duration.zero);
    expect(acquired, isFalse);
    expect(resources.storageWriteScheduler.activeCount, 0);

    pressure.release();
    final lease = await pending;
    expect(acquired, isTrue);
    expect(resources.storageWriteScheduler.activeCount, 1);
    lease.release();
    expect(resources.storageWriteScheduler.activeCount, 0);
  });

  test('storage write quantum capacity serializes independently', () async {
    final reads = ArtifactCacheReadScheduler();
    final writes = StorageWriteScheduler(
      localReadScheduler: reads,
      maxActive: 1,
    );
    final first = await writes.acquireQuantum();
    var secondAcquired = false;
    final secondPending = writes.acquireQuantum().then((lease) {
      secondAcquired = true;
      return lease;
    });
    await Future<void>.delayed(Duration.zero);
    expect(secondAcquired, isFalse);
    expect(writes.activeCount, 1);
    expect(writes.pendingCount, 1);

    first.release();
    final second = await secondPending;
    expect(secondAcquired, isTrue);
    expect(writes.activeCount, 1);
    second.release();
    expect(writes.activeCount, 0);
  });

  test('persistent composition adopts injected network and local-read lanes', () async {
    final root = await Directory.systemTemp.createTemp('zic-resource-owner-');
    final resources = DownloadResourceCoordinator();
    final composition = await PersistentDownloadComposition.open(
      root.path,
      transferNet: resources.networkLane,
      localReadScheduler: resources.localReadScheduler,
    );
    try {
      expect(identical(composition.transferRuntime.net, resources.networkLane), isTrue);
      expect(
        identical(
          composition.transferRuntime.localReadScheduler,
          resources.localReadScheduler,
        ),
        isTrue,
      );
    } finally {
      await composition.close();
      await root.delete(recursive: true);
    }
  });
}

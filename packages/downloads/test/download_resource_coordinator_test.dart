import 'dart:io';

import 'package:downloads/downloads.dart';
import 'package:test/test.dart';

void main() {
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

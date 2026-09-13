import 'dart:io';

import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test('final artifact membership is structural to one cache root', () async {
    final first = await Directory.systemTemp.createTemp('cache-layout-first-');
    final second = await Directory.systemTemp.createTemp('cache-layout-second-');
    addTearDown(() async {
      await first.delete(recursive: true);
      await second.delete(recursive: true);
    });
    final layout = CacheLayout(first.path);

    expect(
      layout.containsFinalArtifactPath(
        '${layout.finalDir}${Platform.pathSeparator}shared-object.bin',
      ),
      isTrue,
    );
    expect(
      layout.containsFinalArtifactPath(
        '${layout.partialDir}${Platform.pathSeparator}shared-object.part',
      ),
      isFalse,
    );
    expect(
      layout.containsFinalArtifactPath(
        '${second.path}${Platform.pathSeparator}final'
        '${Platform.pathSeparator}shared-object.bin',
      ),
      isFalse,
      reason: 'the directory name alone is not authority across storage roots',
    );
  });
}

import 'dart:io';

import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_runtime/reader_runtime.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';

final class _Clock implements MonoClock {
  @override
  int nowMicros() => DateTime.now().microsecondsSinceEpoch;
}

void main() {
  testWidgets('restoring a completed artifact never flashes network progress',
      (tester) async {
    final temp = await Directory.systemTemp.createTemp(
      'reader-download-progress-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final partialPath = '${temp.path}/partial/page.webp';
    final finalPath = '${temp.path}/final/page.webp';
    final first = DownloadSession(
      id: _id(),
      artifact: Artifact(partialPath: partialPath, finalPath: finalPath),
      clock: _Clock(),
    );
    await first.restore();
    final writer = first.acquireWriter();
    await first.append(writer, 0, <int>[1, 2, 3]);
    await first.seal(writer, expectedLength: 3);
    await first.promote();
    await first.dispose();

    final restored = DownloadSession(
      id: _id(),
      artifact: Artifact(partialPath: partialPath, finalPath: finalPath),
      clock: _Clock(),
    );
    addTearDown(() async {
      if (restored.activeRun) return;
      await restored.dispose();
    });
    final publisher = ReaderDownloadProgressPublisher();
    addTearDown(publisher.dispose);
    publisher.observe(restored);
    publisher.select(restored.id);

    final run = restored.beginRun();
    await tester.pump();
    expect(publisher.notifier.value.active, isFalse);

    await restored.restore();
    restored.endRun(run);
    await tester.pump();
    expect(restored.state, DownloadState.promoted);
    expect(publisher.notifier.value.active, isFalse);
  });
}

DownloadId _id() => DownloadId(
      content: const ContentId(
        sourceId: 'venera:fixture',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('venera-resource:fixture'),
    );

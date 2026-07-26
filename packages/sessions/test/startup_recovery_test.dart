import 'dart:io';

import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

final class _Clock implements MonoClock {
  int _value = 0;

  @override
  int nowMicros() => _value++;
}

void main() {
  test('startup recovery scans metadata and restores sessions', () async {
    final temp = await Directory.systemTemp.createTemp('startup_recovery_test_');
    addTearDown(() async => temp.delete(recursive: true));
    final layout = CacheLayout(temp.path);
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/page.webp'),
    );
    final artifact = layout.artifactFor(id);
    await artifact.restore();
    await artifact.writeMeta(<String, Object?>{
      'downloadKey': id.key,
      'download': id.toJson(),
      'validators': const <String, Object?>{'etag': 'v1'},
      'totalLength': 3,
    });
    await artifact.append(0, <int>[1, 2, 3]);
    await artifact.seal(expectedLength: 3);
    await artifact.promote();
    await artifact.dispose();

    final index = MemIndex();
    final clock = _Clock();
    final traces = MemoryTraceSink();
    final registry = DownloadRegistry(
      layout: layout,
      clock: clock,
      index: index,
      traceSink: traces,
    );
    addTearDown(() async {
      await registry.dispose();
      await index.close();
    });

    final report = await StartupRecovery(
      layout: layout,
      index: index,
      registry: registry,
      clock: clock,
      traceSink: traces,
    ).run();

    expect(report.scan.recovered, 1);
    expect(report.sessions, 1);
    expect(registry.find(id)?.state, DownloadState.promoted);
    expect(
      traces.events.where((event) => event.kind == TraceEventKind.cacheScan),
      hasLength(1),
    );
  });
}

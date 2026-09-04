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

  test('startup recovery restores an indexed artifact from its historical root', () async {
    final temp = await Directory.systemTemp.createTemp(
      'startup_recovery_historical_root_test_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final current = CacheLayout('${temp.path}/current');
    final historical = CacheLayout('${temp.path}/historical');
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
    final artifact = historical.legacyArtifactFor(id);
    await artifact.restore();
    await artifact.writeMeta(<String, Object?>{
      'downloadKey': id.legacyKey,
      'download': id.toJson(),
      'validators': const <String, Object?>{},
      'totalLength': 3,
    });
    await artifact.append(0, <int>[1, 2, 3]);
    await artifact.seal(expectedLength: 3);
    await artifact.promote();
    final record = CacheRec(
      id: id,
      state: CacheState.ready,
      path: artifact.finalPath,
      bytes: artifact.committedLength,
      checksum: artifact.checksum,
      createdUs: 1,
      touchedUs: 1,
      storageRootId: historical.root,
    );
    await artifact.dispose();

    final index = MemIndex();
    await index.open();
    await index.put(record);
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: current,
      clock: clock,
      index: index,
      layoutResolver: (_) => current,
    );
    addTearDown(() async {
      await registry.dispose();
      await index.close();
    });

    final report = await StartupRecovery(
      layout: current,
      index: index,
      registry: registry,
      clock: clock,
    ).run();

    expect(report.sessions, 1);
    expect(registry.find(id)?.state, DownloadState.promoted);
    expect(registry.find(id)?.artifact.finalPath, artifact.finalPath);
  });

  test('startup preserves external export bindings without creating local sessions', () async {
    final temp = await Directory.systemTemp.createTemp(
      'startup_recovery_external_binding_test_',
    );
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
    final index = MemIndex();
    await index.open();
    await index.put(
      CacheRec(
        id: id,
        state: CacheState.ready,
        path: 'saf:content%3A%2F%2Ftree?path=comic%2Fpage.jpg',
        bytes: 3,
        checksum: '352441c2',
        createdUs: 1,
        touchedUs: 1,
      ),
    );
    await index.close();

    final registry = DownloadRegistry(
      layout: layout,
      clock: _Clock(),
      index: index,
    );
    addTearDown(() async {
      await registry.dispose();
      await index.close();
    });

    final report = await StartupRecovery(
      layout: layout,
      index: index,
      registry: registry,
      clock: _Clock(),
    ).run();

    expect(report.sessions, 0);
    expect(registry.findExact(id), isNull);
    expect(await index.get(id.key), isNotNull);
  });

  test('eviction of a cold historical artifact uses its indexed path', () async {
    final temp = await Directory.systemTemp.createTemp(
      'historical_artifact_eviction_test_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final current = CacheLayout('${temp.path}/current');
    final historical = CacheLayout('${temp.path}/historical');
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
    final artifact = historical.legacyArtifactFor(id);
    await artifact.restore();
    await artifact.writeMeta(<String, Object?>{
      'downloadKey': id.legacyKey,
      'download': id.toJson(),
      'validators': const <String, Object?>{},
      'totalLength': 3,
    });
    await artifact.append(0, <int>[1, 2, 3]);
    await artifact.seal(expectedLength: 3);
    await artifact.promote();
    final record = CacheRec(
      id: id,
      state: CacheState.ready,
      path: artifact.finalPath,
      bytes: artifact.committedLength,
      checksum: artifact.checksum,
      createdUs: 1,
      touchedUs: 1,
      storageRootId: historical.root,
    );
    await artifact.dispose();

    final index = MemIndex();
    await index.open();
    await index.put(record);
    final registry = DownloadRegistry(
      layout: current,
      clock: _Clock(),
      index: index,
      layoutResolver: (_) => current,
    );
    addTearDown(() async {
      await registry.dispose();
      await index.close();
    });

    expect(await registry.evict(id), 3);
    expect(await File(record.path).exists(), isFalse);
    expect(await index.get(id.key), isNull);
  });
}

import 'dart:io';

import 'package:domain/domain.dart';
import 'package:pipeline/pipeline.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';
import 'package:transport/transport.dart';

final class _Clock implements MonoClock {
  int _value = 0;

  @override
  int nowMicros() => _value++;
}

void main() {
  test('live coordinator runs added download demand through network lane', () async {
    final temp = await Directory.systemTemp.createTemp('live_coordinator_test_');
    addTearDown(() async => temp.delete(recursive: true));
    final source = File('${temp.path}/source.bin');
    await source.writeAsBytes(<int>[1, 2, 3, 4]);

    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: source.uri,
    );
    final index = MemIndex();
    await index.open();
    addTearDown(index.close);
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
      index: index,
    );
    addTearDown(registry.dispose);
    final coordinator = LiveCoordinator(
      registry: registry,
      transportFor: (_) => const FileTransport(),
      clock: clock,
      net: NetLane(maxActive: 1),
    );

    const demand = DownloadDemand(
      role: PageRole.current,
      priority: 1000,
      reason: 'test',
      expirationRevision: 2,
    );
    final plan = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{id: demand},
      decodes: const <DecodeId, DecodeDemand>{},
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{ResourceId.download(id)},
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: plan,
        diff: DemandDiff.between(DemandPlan.empty(), plan),
        window: RoleWindow(const <int, PageRole>{0: PageRole.current}),
      ),
    );

    await coordinator.idle();
    final session = registry.find(id);
    expect(session?.state, DownloadState.promoted);
    expect(await File(session!.artifact.finalPath).readAsBytes(), <int>[1, 2, 3, 4]);
    expect((await index.get(id.key))?.state, CacheState.ready);
  });
}

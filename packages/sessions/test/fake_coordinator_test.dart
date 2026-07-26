import 'package:domain/domain.dart';
import 'package:pipeline/pipeline.dart';
import 'package:sessions/sessions.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

final class _Clock implements MonoClock {
  int value = 0;

  @override
  int nowMicros() => value++;
}

void main() {
  test('fake coordinator applies additions and detachments', () {
    final clock = _Clock();
    final traces = MemoryTraceSink();
    final coordinator = FakeCoordinator(
      clock: clock,
      traceSink: traces,
    );
    const content = ContentId(
      sourceId: 's',
      comicId: 'c',
      chapterId: 'ch',
      pageId: 'p',
    );
    final download = DownloadId(
      content: content,
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('assets/p.png'),
    );
    final demand = const DownloadDemand(
      role: PageRole.current,
      priority: 1000,
      reason: 'test',
      expirationRevision: 2,
    );
    final first = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{download: demand},
      decodes: const <DecodeId, DecodeDemand>{},
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{ResourceId.download(download)},
    );
    final empty = DemandPlan.empty(revision: 2);

    coordinator.reconcile(
      'session',
      PipelineDelta(
        plan: first,
        diff: DemandDiff.between(DemandPlan.empty(), first),
        window: RoleWindow(const <int, PageRole>{0: PageRole.current}),
      ),
    );
    expect(coordinator.downloads, hasLength(1));

    coordinator.reconcile(
      'session',
      PipelineDelta(
        plan: empty,
        diff: DemandDiff.between(first, empty),
        window: RoleWindow(const <int, PageRole>{}),
      ),
    );
    expect(coordinator.downloads, isEmpty);
    expect(
      traces.events.where((event) => event.kind == TraceEventKind.demandDetached),
      hasLength(1),
    );
  });
}

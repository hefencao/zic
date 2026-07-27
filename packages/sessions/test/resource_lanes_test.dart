import 'package:domain/domain.dart';
import 'package:pipeline/pipeline.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';
import 'package:testkit/testkit.dart';
import 'package:transport/transport.dart';

void main() {
  test('decode and upload demands run on their own lanes', () async {
    final id = _decodeId();
    final calls = <String>[];
    final coordinator = LiveCoordinator(
      registry: DownloadRegistry(
        layout: CacheLayout('/tmp/resource_lanes_test'),
        clock: FakeMonoClock(),
      ),
      transportFor: (_) => FakeTransport(bytes: const <int>[]),
      clock: FakeMonoClock(),
      decode: DecodeLane(maxActive: 1),
      upload: UploadLane(maxActive: 1),
      onDecode: (id, demand, token) async {
        calls.add('decode:${demand.targetWatermark}');
      },
      onUpload: (id, demand, token) async {
        calls.add('upload:${demand.priority}');
      },
    );

    final plan = DemandPlan(
      revision: 1,
      downloads: const <DownloadId, DownloadDemand>{},
      decodes: <DecodeId, DecodeDemand>{
        id: const DecodeDemand(
          role: PageRole.current,
          priority: 1000,
          targetWatermark: 2,
          reason: 'test',
          expirationRevision: 1,
        ),
      },
      uploads: <DecodeId, UploadDemand>{
        id: const UploadDemand(
          role: PageRole.current,
          priority: 900,
          reason: 'test',
          expirationRevision: 1,
        ),
      },
      keep: <ResourceId>{ResourceId.decode(id)},
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

    expect(calls, containsAll(<String>['decode:2', 'upload:900']));
  });
}

DecodeId _decodeId() => DecodeId(
      download: DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'page',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('file:///tmp/page.webp'),
      ),
      physicalWidth: 720,
      physicalHeight: 1280,
      pixelFormat: PixelFormat.rgba8888,
      renderer: RendererKind.flutterImage,
    );

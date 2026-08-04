import 'package:domain/domain.dart';
import 'package:pipeline/pipeline.dart';
import 'package:sessions/sessions.dart';
import 'package:test/test.dart';

void main() {
  test('staged waterlines refill one role at a time', () {
    final ids = <PageRole, DecodeId>{
      PageRole.current: _id('c'),
      PageRole.next: _id('n'),
      PageRole.next2: _id('m'),
      PageRole.previous: _id('p'),
    };
    final demands = <DecodeId, DecodeDemand>{
      ids[PageRole.current]!: _demand(PageRole.current, 8),
      ids[PageRole.next]!: _demand(PageRole.next, 6),
      ids[PageRole.next2]!: _demand(PageRole.next2, 4),
      ids[PageRole.previous]!: _demand(PageRole.previous, 3),
    };
    final depth = <DecodeId, int>{for (final id in ids.values) id: 0};
    const policy = StagedDecodeRefillPolicy();

    void expectStep(PageRole role, int target) {
      final decision = policy.next(
        demands: demands,
        depthOf: (id) => depth[id]!,
      );
      expect(decision?.role, role);
      expect(decision?.targetWatermark, target);
      depth[decision!.id] = target;
    }

    expectStep(PageRole.current, 4);
    expectStep(PageRole.next, 2);
    expectStep(PageRole.next2, 2);
    expectStep(PageRole.previous, 2);
    expectStep(PageRole.current, 6);
    expectStep(PageRole.next, 3);
    expectStep(PageRole.current, 8);
    expectStep(PageRole.next, 4);
    expectStep(PageRole.next2, 3);
    expectStep(PageRole.previous, 3);
    expectStep(PageRole.next, 6);
    expectStep(PageRole.next2, 4);
    expect(
      policy.next(demands: demands, depthOf: (id) => depth[id]!),
      isNull,
    );
  });

  test('missing boundary roles do not block later stages', () {
    final current = _id('c');
    final next = _id('n');
    final demands = <DecodeId, DecodeDemand>{
      current: _demand(PageRole.current, 8),
      next: _demand(PageRole.next, 6),
    };
    final depth = <DecodeId, int>{current: 4, next: 2};

    final decision = const StagedDecodeRefillPolicy().next(
      demands: demands,
      depthOf: (id) => depth[id]!,
    );

    expect(decision?.role, PageRole.current);
    expect(decision?.targetWatermark, 6);
  });

  test('ended finite pages do not block neighbor refill', () {
    final current = _id('c');
    final next = _id('n');
    final demands = <DecodeId, DecodeDemand>{
      current: _demand(PageRole.current, 8),
      next: _demand(PageRole.next, 6),
    };

    final decision = const StagedDecodeRefillPolicy().next(
      demands: demands,
      depthOf: (_) => 0,
      terminalOf: (id) => id == current,
    );

    expect(decision?.role, PageRole.next);
    expect(decision?.targetWatermark, 2);
  });
  test('transition is the logical next across every staged watermark', () {
    final current = _id('c');
    final transition = _id('transition');
    final next2 = _id('m');
    final demands = <DecodeId, DecodeDemand>{
      current: _demand(PageRole.current, 8),
      transition: _demand(PageRole.transition, 6),
      next2: _demand(PageRole.next2, 4),
    };
    final depth = <DecodeId, int>{current: 4, transition: 0, next2: 0};
    const policy = StagedDecodeRefillPolicy();

    var decision = policy.next(demands: demands, depthOf: (id) => depth[id]!);
    expect(decision?.id, transition);
    expect(decision?.stage, 'n>1');
    depth[transition] = 2;
    depth[next2] = 2;
    depth[current] = 6;

    decision = policy.next(demands: demands, depthOf: (id) => depth[id]!);
    expect(decision?.id, transition);
    expect(decision?.stage, 'n>2');
  });

}

DecodeDemand _demand(PageRole role, int target) => DecodeDemand(
      role: role,
      priority: 1000,
      targetWatermark: target,
      reason: 'test',
      expirationRevision: 2,
    );

DecodeId _id(String page) => DecodeId(
      download: DownloadId(
        content: ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: page,
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('asset:///$page.webp'),
      ),
      physicalWidth: 1200,
      physicalHeight: 896,
      pixelFormat: PixelFormat.rgba8888,
      renderer: RendererKind.androidTexture,
    );

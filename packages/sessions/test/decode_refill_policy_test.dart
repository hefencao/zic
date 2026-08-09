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
      ids[PageRole.current]!: _demand(PageRole.current, 7),
      ids[PageRole.next]!: _demand(PageRole.next, 5),
      ids[PageRole.next2]!: _demand(PageRole.next2, 3),
      ids[PageRole.previous]!: _demand(PageRole.previous, 2),
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

    expectStep(PageRole.current, 3);
    expectStep(PageRole.next, 2);
    expectStep(PageRole.next2, 2);
    expectStep(PageRole.previous, 2);
    expectStep(PageRole.current, 5);
    expectStep(PageRole.next, 3);
    expectStep(PageRole.current, 7);
    expectStep(PageRole.next, 4);
    expectStep(PageRole.next2, 3);
    expectStep(PageRole.next, 5);
    expect(
      policy.next(demands: demands, depthOf: (id) => depth[id]!),
      isNull,
    );
  });

  test('missing boundary roles do not block later stages', () {
    final current = _id('c');
    final next = _id('n');
    final demands = <DecodeId, DecodeDemand>{
      current: _demand(PageRole.current, 7),
      next: _demand(PageRole.next, 5),
    };
    final depth = <DecodeId, int>{current: 3, next: 2};

    final decision = const StagedDecodeRefillPolicy().next(
      demands: demands,
      depthOf: (id) => depth[id]!,
    );

    expect(decision?.role, PageRole.current);
    expect(decision?.targetWatermark, 5);
  });


  test('authoritative static current is satisfied by one prepared frame', () {
    final current = _id('static-current-with-stale-watermark');
    final animatedNext = _id('animated-next');
    final demands = <DecodeId, DecodeDemand>{
      current: _demand(PageRole.current, 7),
      animatedNext: _demand(PageRole.next, 5),
    };

    final decision = const StagedDecodeRefillPolicy().next(
      demands: demands,
      depthOf: (_) => 0,
      satisfiedOf: (id) => id == current,
    );

    expect(decision?.id, animatedNext);
    expect(decision?.stage, 'n>1');
  });

  test('ended finite pages do not block neighbor refill', () {
    final current = _id('c');
    final next = _id('n');
    final demands = <DecodeId, DecodeDemand>{
      current: _demand(PageRole.current, 7),
      next: _demand(PageRole.next, 5),
    };

    final decision = const StagedDecodeRefillPolicy().next(
      demands: demands,
      depthOf: (_) => 0,
      terminalOf: (id) => id == current,
    );

    expect(decision?.role, PageRole.next);
    expect(decision?.targetWatermark, 2);
  });
  test('single-frame demands bootstrap before staged animation waterlines', () {
    final current = _id('current-static');
    final neighbor = _id('neighbor-static');
    final demands = <DecodeId, DecodeDemand>{
      neighbor: DecodeDemand(
        role: PageRole.next,
        priority: 820,
        targetWatermark: 1,
        reason: 'heuristic:static-warm:next',
        expirationRevision: 2,
      ),
      current: DecodeDemand(
        role: PageRole.current,
        priority: 1000,
        targetWatermark: 1,
        reason: 'heuristic:static-warm:current',
        expirationRevision: 2,
      ),
    };
    final depth = <DecodeId, int>{current: 0, neighbor: 0};

    var decision = const StagedDecodeRefillPolicy().next(
      demands: demands,
      depthOf: (id) => depth[id]!,
    );
    expect(decision?.id, current);
    expect(decision?.stage, 'one>0');
    expect(decision?.targetWatermark, 1);
    depth[current] = 1;

    decision = const StagedDecodeRefillPolicy().next(
      demands: demands,
      depthOf: (id) => depth[id]!,
    );
    expect(decision?.id, neighbor);
    expect(decision?.stage, 'one>0');
  });

  test('animated current waterline outranks lower-priority static warming', () {
    final current = _id('animated-current');
    final neighbor = _id('static-neighbor');
    final demands = <DecodeId, DecodeDemand>{
      current: _demand(PageRole.current, 7),
      neighbor: DecodeDemand(
        role: PageRole.next,
        priority: 820,
        targetWatermark: 1,
        reason: 'heuristic:static-warm:next',
        expirationRevision: 2,
      ),
    };

    final decision = const StagedDecodeRefillPolicy().next(
      demands: demands,
      depthOf: (_) => 0,
    );

    expect(decision?.id, current);
    expect(decision?.stage, 'c>2');
  });

  test('terminal single-frame demand does not block another bootstrap', () {
    final current = _id('ended-static');
    final neighbor = _id('waiting-static');
    final demands = <DecodeId, DecodeDemand>{
      current: _demand(PageRole.current, 1),
      neighbor: _demand(PageRole.next, 1),
    };

    final decision = const StagedDecodeRefillPolicy().next(
      demands: demands,
      depthOf: (_) => 0,
      terminalOf: (id) => id == current,
    );

    expect(decision?.id, neighbor);
    expect(decision?.stage, 'one>0');
  });

  test('current source wait suppresses speculative neighbor decode bootstrap', () {
    final blockedCurrent = _id('blocked-current');
    final readyNext = _id('ready-next');
    final demands = <DecodeId, DecodeDemand>{
      blockedCurrent: _demand(PageRole.current, 7),
      readyNext: _demand(PageRole.next, 5),
    };

    final decision = const StagedDecodeRefillPolicy().next(
      demands: demands,
      depthOf: (_) => 0,
      eligibleOf: (id) => id != blockedCurrent,
    );

    expect(decision, isNull,
        reason: 'Vibe-style shallow bootstrap keeps neighbors download-only while current has no source');
  });

  test('ready current bootstrap outranks transition first frame', () {
    final current = _id('current-low');
    final transition = _id('transition-empty');
    final demands = <DecodeId, DecodeDemand>{
      current: _demand(PageRole.current, 7),
      transition: DecodeDemand(
        role: PageRole.transition,
        priority: 900,
        targetWatermark: 5,
        reason: 'drag-target',
        expirationRevision: 2,
      ),
    };

    final decision = const StagedDecodeRefillPolicy().next(
      demands: demands,
      depthOf: (_) => 0,
    );

    expect(decision?.id, current);
    expect(decision?.stage, 'c>2');
    expect(decision?.targetWatermark, 3);
  });

  test('transition may bootstrap while current is waiting for source', () {
    final current = _id('current-waiting');
    final transition = _id('transition-ready');
    final demands = <DecodeId, DecodeDemand>{
      current: _demand(PageRole.current, 7),
      transition: DecodeDemand(
        role: PageRole.transition,
        priority: 900,
        targetWatermark: 5,
        reason: 'drag-target',
        expirationRevision: 2,
      ),
    };

    final decision = const StagedDecodeRefillPolicy().next(
      demands: demands,
      depthOf: (_) => 0,
      eligibleOf: (id) => id != current,
    );

    expect(decision?.id, transition);
    expect(decision?.stage, 't>0');
    expect(decision?.targetWatermark, 1);
  });

  test('current deepening resumes after transition has its first frame', () {
    final current = _id('current-low');
    final transition = _id('transition-ready');
    final demands = <DecodeId, DecodeDemand>{
      current: _demand(PageRole.current, 7),
      transition: DecodeDemand(
        role: PageRole.transition,
        priority: 900,
        targetWatermark: 5,
        reason: 'drag-target',
        expirationRevision: 2,
      ),
    };
    final depth = <DecodeId, int>{current: 0, transition: 1};

    final decision = const StagedDecodeRefillPolicy().next(
      demands: demands,
      depthOf: (id) => depth[id]!,
    );

    expect(decision?.id, current);
    expect(decision?.stage, 'c>2');
    expect(decision?.targetWatermark, 3);
  });

  test('transition is the logical next across every staged watermark', () {
    final current = _id('c');
    final transition = _id('transition');
    final next2 = _id('m');
    final demands = <DecodeId, DecodeDemand>{
      current: _demand(PageRole.current, 7),
      transition: _demand(PageRole.transition, 5),
      next2: _demand(PageRole.next2, 3),
    };
    final depth = <DecodeId, int>{current: 3, transition: 0, next2: 0};
    const policy = StagedDecodeRefillPolicy();

    var decision = policy.next(demands: demands, depthOf: (id) => depth[id]!);
    expect(decision?.id, transition);
    expect(decision?.stage, 't>0');
    depth[transition] = 2;
    depth[next2] = 2;
    depth[current] = 5;

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

import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

void main() {
  const analyzer = ReaderTransitionTraceAnalyzer();
  const identity = ReaderTraceIdentity(
    pageAssetKey: 'chapter/page-1',
    resourceKeyPrefix: 'source/comic/chapter/page-1|r1|asset:///page-1.webp',
  );

  test('derives deterministic transition phase durations', () {
    final events = <TraceEvent>[
      _event(10, TraceEventKind.artifactSource,
          identity: identity.resourceKeyPrefix,
          revision: 4,
          payload: const <String, Object?>{'source': 'artifact-cache'}),
      _event(20, TraceEventKind.decodeDemand,
          identity: '${identity.resourceKeyPrefix}|decode', revision: 4),
      _event(35, TraceEventKind.decodeStarted,
          identity: '${identity.resourceKeyPrefix}|decode', revision: 4),
      _event(60, TraceEventKind.frameDecoded,
          identity: '${identity.resourceKeyPrefix}|decode', revision: 4),
      _event(25, TraceEventKind.uploadDemand,
          identity: '${identity.resourceKeyPrefix}|decode', revision: 4),
      _event(70, TraceEventKind.uploadStarted,
          identity: '${identity.resourceKeyPrefix}|decode', revision: 4),
      _event(90, TraceEventKind.frameUploaded,
          identity: '${identity.resourceKeyPrefix}|decode', revision: 4),
      _event(96, TraceEventKind.framePresented,
          identity: '${identity.resourceKeyPrefix}|decode', revision: 4),
      _event(80, TraceEventKind.pageHostMounted,
          identity: identity.pageAssetKey, revision: 4),
      _event(100, TraceEventKind.pageTransition,
          identity: identity.pageAssetKey, revision: 4),
      _event(112, TraceEventKind.firstFrameReady,
          identity: identity.pageAssetKey, revision: 4),
    ];

    final analysis = analyzer.analyze(
      events: events,
      sessionId: 'reader-1',
      revision: 4,
      identity: identity,
    );

    expect(analysis.artifactSource, ReaderArtifactSource.artifactCache);
    expect(analysis.workRevision, 4);
    expect(analysis.transitionToFirstFrame, const Duration(microseconds: 12));
    expect(analysis.toJson()['transitionToFirstFrameMicros'], 12);
    expect(analysis.decodeQueue, const Duration(microseconds: 15));
    expect(analysis.decodeWork, const Duration(microseconds: 25));
    expect(analysis.uploadQueue, const Duration(microseconds: 45));
    expect(analysis.uploadWork, const Duration(microseconds: 20));
    expect(analysis.presentation, const Duration(microseconds: 6));
    expect(
      analysis.dominantMeasuredPhase,
      ReaderTransitionPhase.uploadQueue,
    );
    expect(analysis.hostRemountedAfterTransition, isFalse);
    expect(analysis.isComplete, isTrue);
  });

  test('recognizes a neighboring page ready before the midpoint', () {
    final events = <TraceEvent>[
      _event(30, TraceEventKind.pageHostMounted,
          identity: identity.pageAssetKey, revision: 3),
      _event(40, TraceEventKind.firstFrameReady,
          identity: identity.pageAssetKey, revision: 3),
      _event(100, TraceEventKind.pageTransition,
          identity: identity.pageAssetKey, revision: 4),
    ];

    final analysis = analyzer.analyze(
      events: events,
      sessionId: 'reader-1',
      revision: 4,
      identity: identity,
    );

    expect(analysis.firstFrameReadyBeforeTransition, isTrue);
    expect(analysis.firstFrameRevision, 3);
    expect(analysis.workRevision, 3);
    expect(analysis.transitionToFirstFrame, Duration.zero);
    expect(analysis.reachedFirstFrame, isTrue);
  });

  test('reports origin fallback and host remount evidence', () {
    final events = <TraceEvent>[
      _event(90, TraceEventKind.artifactSource,
          identity: identity.resourceKeyPrefix,
          revision: 9,
          payload: const <String, Object?>{'source': 'origin'}),
      _event(100, TraceEventKind.pageTransition,
          identity: identity.pageAssetKey, revision: 9),
      _event(105, TraceEventKind.pageHostDisposed,
          identity: identity.pageAssetKey, revision: 9),
      _event(108, TraceEventKind.pageHostMounted,
          identity: identity.pageAssetKey, revision: 9),
      _event(150, TraceEventKind.firstFrameReady,
          identity: identity.pageAssetKey, revision: 9),
    ];

    final analysis = analyzer.analyze(
      events: events,
      sessionId: 'reader-1',
      revision: 9,
      identity: identity,
    );

    expect(analysis.artifactSource, ReaderArtifactSource.origin);
    expect(analysis.hostDisposedAfterTransition, isTrue);
    expect(analysis.hostRemountedAfterTransition, isTrue);
    expect(analysis.reachedFirstFrame, isTrue);
    expect(analysis.isComplete, isFalse);
    expect(analysis.missingEvents, contains(TraceEventKind.decodeDemand));
  });

  test('analyzeAll rejects duplicate page identity declarations', () {
    expect(
      () => analyzer.analyzeAll(
        events: const <TraceEvent>[],
        identities: const <ReaderTraceIdentity>[identity, identity],
      ),
      throwsArgumentError,
    );
  });

  test('analyzeAll separates rapid-swipe revisions and pages', () {
    const second = ReaderTraceIdentity(
      pageAssetKey: 'chapter/page-2',
      resourceKeyPrefix: 'source/comic/chapter/page-2|r1|asset:///page-2.webp',
    );
    final events = <TraceEvent>[
      _event(10, TraceEventKind.pageTransition,
          identity: identity.pageAssetKey, revision: 2),
      _event(11, TraceEventKind.pageTransition,
          identity: identity.pageAssetKey, revision: 2),
      _event(20, TraceEventKind.pageTransition,
          identity: second.pageAssetKey, revision: 3),
    ];

    final analyses = analyzer.analyzeAll(
      events: events,
      identities: const <ReaderTraceIdentity>[identity, second],
    );

    expect(analyses, hasLength(2));
    expect(analyses[0].revision, 2);
    expect(analyses[0].identity.pageAssetKey, identity.pageAssetKey);
    expect(analyses[0].wasSuperseded, isTrue);
    expect(analyses[0].supersededAtMicros, 20);
    expect(analyses[1].revision, 3);
    expect(analyses[1].identity.pageAssetKey, second.pageAssetKey);
  });
}

TraceEvent _event(
  int micros,
  TraceEventKind kind, {
  required String identity,
  required int revision,
  Map<String, Object?> payload = const <String, Object?>{},
}) =>
    TraceEvent(
      monotonicMicros: micros,
      sessionId: 'reader-1',
      kind: kind,
      identityHash: identity,
      revision: revision,
      payload: payload,
    );

import 'trace.dart';

enum ReaderArtifactSource {
  artifactCache,
  origin,
  unknown,
}

enum ReaderTransitionPhase {
  decodeQueue,
  decode,
  uploadQueue,
  upload,
  presentation,
}

/// Links Reader page identity to the Download/Decode identity prefix emitted by
/// pipeline and session telemetry.
final class ReaderTraceIdentity {
  const ReaderTraceIdentity({
    required this.pageAssetKey,
    required this.resourceKeyPrefix,
  })  : assert(pageAssetKey != ''),
        assert(resourceKeyPrefix != '');

  final String pageAssetKey;
  final String resourceKeyPrefix;

  bool matchesPage(TraceEvent event) => event.identityHash == pageAssetKey;

  bool matchesResource(TraceEvent event) {
    final identity = event.identityHash;
    return identity == resourceKeyPrefix ||
        (identity?.startsWith('$resourceKeyPrefix|') ?? false);
  }
}

final class ReaderTransitionAnalysis {
  ReaderTransitionAnalysis({
    required this.sessionId,
    required this.revision,
    required this.identity,
    required this.transitionAtMicros,
    required this.artifactSource,
    required this.hostDisposedAfterTransition,
    required this.hostRemountedAfterTransition,
    required this.firstFrameReadyBeforeTransition,
    required this.firstFrameRevision,
    required this.workRevision,
    required this.supersededAtMicros,
    required this.transitionToFirstFrame,
    required this.decodeQueue,
    required this.decodeWork,
    required this.uploadQueue,
    required this.uploadWork,
    required this.presentation,
    required Iterable<TraceEventKind> missingEvents,
  }) : missingEvents = Set<TraceEventKind>.unmodifiable(missingEvents);

  final String sessionId;
  final int revision;
  final ReaderTraceIdentity identity;
  final int transitionAtMicros;
  final ReaderArtifactSource artifactSource;
  final bool hostDisposedAfterTransition;
  final bool hostRemountedAfterTransition;
  final bool firstFrameReadyBeforeTransition;
  final int? firstFrameRevision;
  final int workRevision;
  final int? supersededAtMicros;
  final Duration? transitionToFirstFrame;
  final Duration? decodeQueue;
  final Duration? decodeWork;
  final Duration? uploadQueue;
  final Duration? uploadWork;
  final Duration? presentation;
  final Set<TraceEventKind> missingEvents;

  bool get reachedFirstFrame => transitionToFirstFrame != null;
  bool get wasSuperseded => supersededAtMicros != null;
  bool get isComplete => reachedFirstFrame && missingEvents.isEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
        'sessionId': sessionId,
        'transitionRevision': revision,
        'workRevision': workRevision,
        'pageAssetKey': identity.pageAssetKey,
        'resourceKeyPrefix': identity.resourceKeyPrefix,
        'transitionAtMicros': transitionAtMicros,
        'artifactSource': artifactSource.name,
        'hostDisposedAfterTransition': hostDisposedAfterTransition,
        'hostRemountedAfterTransition': hostRemountedAfterTransition,
        'firstFrameReadyBeforeTransition': firstFrameReadyBeforeTransition,
        if (firstFrameRevision != null)
          'firstFrameRevision': firstFrameRevision,
        if (supersededAtMicros != null)
          'supersededAtMicros': supersededAtMicros,
        if (transitionToFirstFrame != null)
          'transitionToFirstFrameMicros':
              transitionToFirstFrame!.inMicroseconds,
        if (decodeQueue != null)
          'decodeQueueMicros': decodeQueue!.inMicroseconds,
        if (decodeWork != null) 'decodeWorkMicros': decodeWork!.inMicroseconds,
        if (uploadQueue != null)
          'uploadQueueMicros': uploadQueue!.inMicroseconds,
        if (uploadWork != null) 'uploadWorkMicros': uploadWork!.inMicroseconds,
        if (presentation != null)
          'presentationMicros': presentation!.inMicroseconds,
        if (dominantMeasuredPhase != null)
          'dominantMeasuredPhase': dominantMeasuredPhase!.name,
        'missingEvents': missingEvents.map((event) => event.name).toList(),
      };

  ReaderTransitionPhase? get dominantMeasuredPhase {
    final phases = <MapEntry<ReaderTransitionPhase, Duration>>[
      if (decodeQueue != null)
        MapEntry<ReaderTransitionPhase, Duration>(
          ReaderTransitionPhase.decodeQueue,
          decodeQueue!,
        ),
      if (decodeWork != null)
        MapEntry<ReaderTransitionPhase, Duration>(
          ReaderTransitionPhase.decode,
          decodeWork!,
        ),
      if (uploadQueue != null)
        MapEntry<ReaderTransitionPhase, Duration>(
          ReaderTransitionPhase.uploadQueue,
          uploadQueue!,
        ),
      if (uploadWork != null)
        MapEntry<ReaderTransitionPhase, Duration>(
          ReaderTransitionPhase.upload,
          uploadWork!,
        ),
      if (presentation != null)
        MapEntry<ReaderTransitionPhase, Duration>(
          ReaderTransitionPhase.presentation,
          presentation!,
        ),
    ];
    if (phases.isEmpty) {
      return null;
    }
    var dominant = phases.first;
    for (final phase in phases.skip(1)) {
      if (phase.value > dominant.value) {
        dominant = phase;
      }
    }
    return dominant.key;
  }
}

/// Deterministic replay of the already-recorded Reader transition chain.
///
/// This analyzer is observational only. It does not infer demand, retain pages,
/// mutate cache state, or choose a prefetch/eviction policy.
final class ReaderTransitionTraceAnalyzer {
  const ReaderTransitionTraceAnalyzer();

  List<ReaderTransitionAnalysis> analyzeAll({
    required Iterable<TraceEvent> events,
    required Iterable<ReaderTraceIdentity> identities,
  }) {
    final ordered = events.toList()
      ..sort((left, right) =>
          left.monotonicMicros.compareTo(right.monotonicMicros));
    final byPage = <String, ReaderTraceIdentity>{};
    for (final identity in identities) {
      if (byPage.containsKey(identity.pageAssetKey)) {
        throw ArgumentError.value(
          identity.pageAssetKey,
          'identities',
          'contains a duplicate page asset key',
        );
      }
      byPage[identity.pageAssetKey] = identity;
    }
    final seen = <String>{};
    final result = <ReaderTransitionAnalysis>[];
    for (final event in ordered) {
      if (event.kind != TraceEventKind.pageTransition ||
          event.revision == null) {
        continue;
      }
      final identity = byPage[event.identityHash];
      if (identity == null) {
        continue;
      }
      final key = '${event.sessionId}\u0000${event.revision}\u0000'
          '${identity.pageAssetKey}';
      if (!seen.add(key)) {
        continue;
      }
      result.add(
        analyze(
          events: ordered,
          sessionId: event.sessionId,
          revision: event.revision!,
          identity: identity,
        ),
      );
    }
    return List<ReaderTransitionAnalysis>.unmodifiable(result);
  }

  ReaderTransitionAnalysis analyze({
    required Iterable<TraceEvent> events,
    required String sessionId,
    required int revision,
    required ReaderTraceIdentity identity,
  }) {
    final ordered = events
        .where((event) => event.sessionId == sessionId)
        .toList()
      ..sort((left, right) =>
          left.monotonicMicros.compareTo(right.monotonicMicros));
    final transition = _first(
      ordered,
      kind: TraceEventKind.pageTransition,
      revision: revision,
      matches: identity.matchesPage,
    );
    if (transition == null) {
      throw StateError(
        'no pageTransition for ${identity.pageAssetKey} at revision $revision',
      );
    }

    final nextTransition = _first(
      ordered,
      kind: TraceEventKind.pageTransition,
      matches: (event) =>
          event.revision != revision ||
          event.identityHash != identity.pageAssetKey,
      notBeforeMicros: transition.monotonicMicros + 1,
    );
    final windowEnd = nextTransition?.monotonicMicros;
    final disposed = _first(
      ordered,
      kind: TraceEventKind.pageHostDisposed,
      matches: identity.matchesPage,
      notBeforeMicros: transition.monotonicMicros,
      notAfterMicros: windowEnd,
    );
    final remounted = disposed == null
        ? null
        : _first(
            ordered,
            kind: TraceEventKind.pageHostMounted,
            matches: identity.matchesPage,
            notBeforeMicros: disposed.monotonicMicros,
            notAfterMicros: windowEnd,
          );
    final mountedBeforeTransition = _last(
      ordered,
      kind: TraceEventKind.pageHostMounted,
      matches: identity.matchesPage,
      notAfterMicros: transition.monotonicMicros,
    );
    final disposedBeforeTransition = _last(
      ordered,
      kind: TraceEventKind.pageHostDisposed,
      matches: identity.matchesPage,
      notAfterMicros: transition.monotonicMicros,
    );
    final hostMountedAtTransition = mountedBeforeTransition != null &&
        (disposedBeforeTransition == null ||
            mountedBeforeTransition.monotonicMicros >
                disposedBeforeTransition.monotonicMicros);
    final readyBeforeTransition = disposed == null && hostMountedAtTransition
        ? _last(
            ordered,
            kind: TraceEventKind.firstFrameReady,
            matches: identity.matchesPage,
            notBeforeMicros: mountedBeforeTransition!.monotonicMicros,
            notAfterMicros: transition.monotonicMicros,
          )
        : null;
    final firstFrame = readyBeforeTransition ??
        _first(
          ordered,
          kind: TraceEventKind.firstFrameReady,
          matches: identity.matchesPage,
          notBeforeMicros:
              remounted?.monotonicMicros ?? transition.monotonicMicros,
          notAfterMicros: windowEnd,
        );
    final horizon = firstFrame?.monotonicMicros ?? windowEnd;
    final workWindowStart = remounted?.monotonicMicros ??
        mountedBeforeTransition?.monotonicMicros ??
        transition.monotonicMicros;
    final presentedForFirstFrame = _last(
      ordered,
      kind: TraceEventKind.framePresented,
      matches: identity.matchesResource,
      notBeforeMicros: workWindowStart,
      notAfterMicros: horizon,
    );
    final workRevision = presentedForFirstFrame?.revision ??
        firstFrame?.revision ??
        revision;
    final artifact = _first(
      ordered,
      kind: TraceEventKind.artifactSource,
      revision: workRevision,
      matches: identity.matchesResource,
      notAfterMicros: horizon,
    );
    final decodeDemand = _first(
      ordered,
      kind: TraceEventKind.decodeDemand,
      revision: workRevision,
      matches: identity.matchesResource,
      notAfterMicros: horizon,
    );
    final decodeStarted = _first(
      ordered,
      kind: TraceEventKind.decodeStarted,
      revision: workRevision,
      matches: identity.matchesResource,
      notAfterMicros: horizon,
    );
    final frameDecoded = _first(
      ordered,
      kind: TraceEventKind.frameDecoded,
      revision: workRevision,
      matches: identity.matchesResource,
      notAfterMicros: horizon,
    );
    final uploadDemand = _first(
      ordered,
      kind: TraceEventKind.uploadDemand,
      revision: workRevision,
      matches: identity.matchesResource,
      notAfterMicros: horizon,
    );
    final uploadStarted = _first(
      ordered,
      kind: TraceEventKind.uploadStarted,
      revision: workRevision,
      matches: identity.matchesResource,
      notAfterMicros: horizon,
    );
    final frameUploaded = _first(
      ordered,
      kind: TraceEventKind.frameUploaded,
      revision: workRevision,
      matches: identity.matchesResource,
      notAfterMicros: horizon,
    );
    final framePresented = presentedForFirstFrame?.revision == workRevision
        ? presentedForFirstFrame
        : _first(
            ordered,
            kind: TraceEventKind.framePresented,
            revision: workRevision,
            matches: identity.matchesResource,
            notAfterMicros: horizon,
          );
    final missing = <TraceEventKind>{
      if (artifact == null) TraceEventKind.artifactSource,
      if (decodeDemand == null) TraceEventKind.decodeDemand,
      if (decodeStarted == null) TraceEventKind.decodeStarted,
      if (frameDecoded == null) TraceEventKind.frameDecoded,
      if (uploadDemand == null) TraceEventKind.uploadDemand,
      if (uploadStarted == null) TraceEventKind.uploadStarted,
      if (frameUploaded == null) TraceEventKind.frameUploaded,
      if (framePresented == null) TraceEventKind.framePresented,
      if (firstFrame == null) TraceEventKind.firstFrameReady,
    };

    return ReaderTransitionAnalysis(
      sessionId: sessionId,
      revision: revision,
      identity: identity,
      transitionAtMicros: transition.monotonicMicros,
      artifactSource: _artifactSource(artifact),
      hostDisposedAfterTransition: disposed != null,
      hostRemountedAfterTransition: disposed != null && remounted != null,
      firstFrameReadyBeforeTransition: readyBeforeTransition != null,
      firstFrameRevision: firstFrame?.revision,
      workRevision: workRevision,
      supersededAtMicros: nextTransition?.monotonicMicros,
      transitionToFirstFrame: readyBeforeTransition != null
          ? Duration.zero
          : _duration(transition, firstFrame),
      decodeQueue: _duration(decodeDemand, decodeStarted),
      decodeWork: _duration(decodeStarted, frameDecoded),
      uploadQueue: _duration(uploadDemand, uploadStarted),
      uploadWork: _duration(uploadStarted, frameUploaded),
      presentation: _duration(frameUploaded, framePresented),
      missingEvents: missing,
    );
  }
}

TraceEvent? _first(
  Iterable<TraceEvent> events, {
  required TraceEventKind kind,
  required bool Function(TraceEvent event) matches,
  int? revision,
  int? notBeforeMicros,
  int? notAfterMicros,
}) {
  for (final event in events) {
    if (event.kind != kind ||
        (revision != null && event.revision != revision) ||
        !matches(event) ||
        (notBeforeMicros != null &&
            event.monotonicMicros < notBeforeMicros) ||
        (notAfterMicros != null && event.monotonicMicros > notAfterMicros)) {
      continue;
    }
    return event;
  }
  return null;
}

TraceEvent? _last(
  Iterable<TraceEvent> events, {
  required TraceEventKind kind,
  required bool Function(TraceEvent event) matches,
  int? notBeforeMicros,
  int? notAfterMicros,
}) {
  TraceEvent? result;
  for (final event in events) {
    if (event.kind != kind ||
        !matches(event) ||
        (notBeforeMicros != null &&
            event.monotonicMicros < notBeforeMicros) ||
        (notAfterMicros != null && event.monotonicMicros > notAfterMicros)) {
      continue;
    }
    result = event;
  }
  return result;
}

Duration? _duration(TraceEvent? start, TraceEvent? end) {
  if (start == null ||
      end == null ||
      end.monotonicMicros < start.monotonicMicros) {
    return null;
  }
  return Duration(
    microseconds: end.monotonicMicros - start.monotonicMicros,
  );
}

ReaderArtifactSource _artifactSource(TraceEvent? event) {
  return switch (event?.payload['source']) {
    'artifact-cache' => ReaderArtifactSource.artifactCache,
    'origin' => ReaderArtifactSource.origin,
    _ => ReaderArtifactSource.unknown,
  };
}

import 'dart:convert';

import 'clock.dart';

enum TraceEventKind {
  homeBootstrapPresented,
  homeServicesOpenStarted,
  homeServiceReady,
  homeServicesReady,
  homeCoverRequested,
  homeCoverSourceReady,
  homeCoverFirstFrame,
  readerObservation,
  pageTransition,
  pageCurrent,
  pageHostMounted,
  pageHostDisposed,
  firstFrameReady,
  policyDecision,
  demandApplied,
  demandDetached,
  staleWorkRejected,
  downloadState,
  bytesCommitted,
  artifactSealed,
  artifactPromoted,
  resumeAccepted,
  resumeRestarted,
  writerRejected,
  taskFailed,
  cacheScan,
  cacheTrim,
  retryScheduled,
  artifactSource,
  decodeDemand,
  decodeStarted,
  decodeState,
  frameDecoded,
  animationLoop,
  uploadState,
  frameUploaded,
  framePresented,
  sourceReady,
  sourceDisabled,
  uploadDemand,
  uploadStarted,
  frameBudget,
}

final class TraceEvent {
  TraceEvent({
    required this.monotonicMicros,
    required this.sessionId,
    required this.kind,
    this.identityHash,
    this.revision,
    this.epoch,
    Map<String, Object?> payload = const <String, Object?>{},
  }) : payload = Map<String, Object?>.unmodifiable(payload);

  final int monotonicMicros;
  final String sessionId;
  final TraceEventKind kind;
  final String? identityHash;
  final int? revision;
  final int? epoch;
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => <String, Object?>{
        't': monotonicMicros,
        'sessionId': sessionId,
        'kind': kind.name,
        if (identityHash != null) 'identityHash': identityHash,
        if (revision != null) 'revision': revision,
        if (epoch != null) 'epoch': epoch,
        if (payload.isNotEmpty) 'payload': payload,
      };

  String toJsonLine() => jsonEncode(toJson());
}

abstract interface class TraceSink {
  void record(TraceEvent event);
}

final class NoopTraceSink implements TraceSink {
  const NoopTraceSink();

  @override
  void record(TraceEvent event) {}
}

final class MemoryTraceSink implements TraceSink {
  final List<TraceEvent> _events = <TraceEvent>[];

  List<TraceEvent> get events => List<TraceEvent>.unmodifiable(_events);

  @override
  void record(TraceEvent event) {
    _events.add(event);
  }

  void clear() => _events.clear();
}

final class CallbackTraceSink implements TraceSink {
  const CallbackTraceSink(this.callback);

  final void Function(TraceEvent event) callback;

  @override
  void record(TraceEvent event) => callback(event);
}

final class MultiTraceSink implements TraceSink {
  MultiTraceSink(Iterable<TraceSink> sinks)
      : _sinks = List<TraceSink>.unmodifiable(sinks);

  final List<TraceSink> _sinks;

  @override
  void record(TraceEvent event) {
    for (final sink in _sinks) {
      sink.record(event);
    }
  }
}

TraceEvent traceEvent({
  required MonoClock clock,
  required String sessionId,
  required TraceEventKind kind,
  String? identityHash,
  int? revision,
  int? epoch,
  Map<String, Object?> payload = const <String, Object?>{},
}) {
  return TraceEvent(
    monotonicMicros: clock.nowMicros(),
    sessionId: sessionId,
    kind: kind,
    identityHash: identityHash,
    revision: revision,
    epoch: epoch,
    payload: payload,
  );
}

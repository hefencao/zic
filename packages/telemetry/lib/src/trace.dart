import 'dart:convert';

import 'clock.dart';

enum TraceEventKind {
  homeBootstrapPresented,
  homeServicesOpenStarted,
  homeServiceReady,
  homeServicesReady,
  homeCoverRequested,
  homeCoverSourceReady,
  homeCoverSourceFailed,
  homeCoverDecodeFailed,
  homeCoverFirstFrame,
  readerSessionCreated,
  readerSessionRetained,
  readerSessionReused,
  readerSessionDisposeStarted,
  readerSessionDisposed,
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
  downloadStarted,
  downloadPriorityChanged,
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
  sourceRead,
  pageOutputReleased,
  decodeDemand,
  decodePriorityPromoted,
  decodeRefill,
  decodeStarted,
  decodeState,
  frameDecoded,
  animationLoop,
  mediaClassified,
  uploadState,
  frameUploaded,
  lastFrameKept,
  staticFrameKept,
  framePresented,
  framePipelineTiming,
  playbackFrameDue,
  playbackBuffering,
  playbackCompleted,
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
    String? identityHash,
    this.revision,
    this.epoch,
    Map<String, Object?> payload = const <String, Object?>{},
  })  : identityHash = identityHash == null
            ? null
            : _sanitizeTraceIdentity(identityHash),
        payload = Map<String, Object?>.unmodifiable(
          _sanitizeTraceMap(payload),
        );

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

String _sanitizeTraceIdentity(String value) {
  final sanitized = _sanitizeTraceString(value);
  if (sanitized.length <= 160) {
    return sanitized;
  }
  return _traceOpaqueSummary('identity', sanitized);
}

Map<String, Object?> _sanitizeTraceMap(Map<String, Object?> value) =>
    <String, Object?>{
      for (final entry in value.entries)
        entry.key: _sanitizeTraceValue(entry.value),
    };

Object? _sanitizeTraceValue(Object? value) => switch (value) {
      String text => _sanitizeTraceString(text),
      Map<Object?, Object?> map => <String, Object?>{
          for (final entry in map.entries)
            entry.key.toString(): _sanitizeTraceValue(entry.value),
        },
      Iterable<Object?> values =>
        values.map<Object?>(_sanitizeTraceValue).toList(growable: false),
      _ => value,
    };

String _sanitizeTraceString(String value) {
  var sanitized = value.replaceAllMapped(
    RegExp(r'venera-resource:(?://[^|\s"}]+|[A-Za-z0-9_-]{24,})'),
    (match) => _traceOpaqueSummary('venera-resource', match.group(0)!),
  );
  sanitized = sanitized.replaceAllMapped(
    RegExp(r'venera:(comic|chapter):[A-Za-z0-9_-]{24,}'),
    (match) => _traceOpaqueSummary(
      'venera:${match.group(1)}',
      match.group(0)!,
    ),
  );
  sanitized = sanitized.replaceAllMapped(
    RegExp(r'mihon:(manga|chapter|resource):[A-Za-z0-9_-]{24,}'),
    (match) => _traceOpaqueSummary(
      'mihon:${match.group(1)}',
      match.group(0)!,
    ),
  );
  return sanitized;
}

String _traceOpaqueSummary(String kind, String value) =>
    '$kind:<${_traceHash(value)},${value.length}>';

String _traceHash(String value) {
  var hash = 0xcbf29ce484222325;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

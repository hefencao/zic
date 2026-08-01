import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:telemetry/telemetry.dart';

enum TraceHighlightLevel { normal, activity, warning, error }

TraceHighlightLevel traceHighlightLevel(TraceEvent event) =>
    switch (event.kind) {
      TraceEventKind.taskFailed ||
      TraceEventKind.writerRejected ||
      TraceEventKind.sourceDisabled => TraceHighlightLevel.error,
      TraceEventKind.retryScheduled ||
      TraceEventKind.staleWorkRejected ||
      TraceEventKind.resumeRestarted ||
      TraceEventKind.cacheTrim => TraceHighlightLevel.warning,
      TraceEventKind.pageHostMounted ||
      TraceEventKind.pageHostDisposed ||
      TraceEventKind.readerObservation ||
      TraceEventKind.pageTransition ||
      TraceEventKind.pageCurrent ||
      TraceEventKind.decodeDemand ||
      TraceEventKind.uploadDemand ||
      TraceEventKind.framePresented => TraceHighlightLevel.activity,
      _ => TraceHighlightLevel.normal,
    };

/// Bounded, compact UI projection of trace events.
///
/// Producers and durable telemetry keep every event. This read model only
/// coalesces consecutive high-frequency lifecycle events so opening a long
/// continuous chapter does not make the debug surface unusable.
final class DebugTraceLog extends ChangeNotifier implements TraceSink {
  DebugTraceLog({this.maxEvents = 500, bool enabled = true})
      : assert(maxEvents > 0),
        _enabled = enabled;

  static const int _coalesceWindowMicros = 250000;
  static const Set<TraceEventKind> _coalescibleKinds = <TraceEventKind>{
    TraceEventKind.pageHostMounted,
    TraceEventKind.pageHostDisposed,
    TraceEventKind.readerObservation,
    TraceEventKind.pageTransition,
    TraceEventKind.decodeDemand,
    TraceEventKind.uploadDemand,
    TraceEventKind.framePresented,
  };

  final int maxEvents;
  final List<TraceEvent> _events = <TraceEvent>[];
  bool _enabled;
  bool _disposed = false;
  bool _notificationScheduled = false;
  int _recordedCount = 0;
  int _coalescedCount = 0;

  bool get enabled => _enabled;
  int get recordedCount => _recordedCount;
  int get coalescedCount => _coalescedCount;
  List<TraceEvent> get events => List<TraceEvent>.unmodifiable(_events);
  Set<String> get sessionIds => Set<String>.unmodifiable(
        _events.map((event) => event.sessionId),
      );

  set enabled(bool value) {
    if (_disposed || _enabled == value) return;
    _enabled = value;
    _scheduleNotification();
  }

  @override
  void record(TraceEvent event) {
    if (_disposed || !_enabled) return;
    _recordedCount++;
    if (_tryCoalesce(event)) {
      _coalescedCount++;
    } else {
      _events.add(event);
    }
    final overflow = _events.length - maxEvents;
    if (overflow > 0) {
      _events.removeRange(0, overflow);
    }
    _scheduleNotification();
  }

  bool _tryCoalesce(TraceEvent event) {
    if (_events.isEmpty || !_coalescibleKinds.contains(event.kind)) {
      return false;
    }
    final prior = _events.last;
    if (prior.kind != event.kind ||
        prior.sessionId != event.sessionId ||
        event.monotonicMicros - prior.monotonicMicros >
            _coalesceWindowMicros) {
      return false;
    }
    final priorCount = prior.payload['coalescedCount'];
    final count = priorCount is int ? priorCount : 1;
    final firstPage = prior.payload['firstPageIndex'] ??
        prior.payload['pageIndex'];
    final lastPage = event.payload['pageIndex'] ??
        prior.payload['lastPageIndex'] ??
        prior.payload['pageIndex'];
    _events[_events.length - 1] = TraceEvent(
      monotonicMicros: event.monotonicMicros,
      sessionId: event.sessionId,
      kind: event.kind,
      identityHash: event.identityHash ?? prior.identityHash,
      revision: event.revision ?? prior.revision,
      epoch: event.epoch ?? prior.epoch,
      payload: <String, Object?>{
        ...event.payload,
        'coalescedCount': count + 1,
        if (firstPage != null) 'firstPageIndex': firstPage,
        if (lastPage != null) 'lastPageIndex': lastPage,
      },
    );
    return true;
  }

  void clear() {
    if (_disposed || (_events.isEmpty && _recordedCount == 0)) return;
    _events.clear();
    _recordedCount = 0;
    _coalescedCount = 0;
    _scheduleNotification();
  }

  void _scheduleNotification() {
    if (_disposed || _notificationScheduled) return;
    _notificationScheduled = true;
    final binding = SchedulerBinding.instance;
    binding.addPostFrameCallback((_) {
      _notificationScheduled = false;
      if (!_disposed) notifyListeners();
    });
    binding.scheduleFrame();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

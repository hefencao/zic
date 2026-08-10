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
      TraceEventKind.readerSessionCreated ||
      TraceEventKind.readerSessionDisposeStarted ||
      TraceEventKind.readerSessionDisposed ||
      TraceEventKind.pageHostMounted ||
      TraceEventKind.pageHostDisposed ||
      TraceEventKind.readerObservation ||
      TraceEventKind.pageTransition ||
      TraceEventKind.pageCurrent ||
      TraceEventKind.decodeDemand ||
      TraceEventKind.uploadDemand ||
      TraceEventKind.sourceRead ||
      TraceEventKind.pageOutputReleased ||
      TraceEventKind.framePresented ||
      TraceEventKind.framePipelineTiming ||
      TraceEventKind.playbackFrameDue ||
      TraceEventKind.playbackCompleted => TraceHighlightLevel.activity,
      _ => TraceHighlightLevel.normal,
    };

/// Bounded trace owner with compact export and UI projections.
///
/// The export projection never coalesces errors or authoritative lifecycle
/// edges. High-frequency frame, scroll, state and byte-progress events are
/// folded into short timed buckets, retaining count, first/last positions and
/// timing ranges. Both projections remain bounded and report capacity eviction.
final class DebugTraceLog extends ChangeNotifier implements TraceSink {
  DebugTraceLog({
    this.maxEvents = 500,
    this.maxExportEvents = 10000,
    bool enabled = true,
  })  : assert(maxEvents > 0),
        assert(maxExportEvents >= maxEvents),
        _enabled = enabled;

  static const int _coalesceWindowMicros = 250000;
  static const int _exportDefaultWindowMicros = 500000;
  static const int _exportFrameWindowMicros = 1000000;
  static const int _exportScrollWindowMicros = 250000;
  static const Set<TraceEventKind> _coalescibleKinds = <TraceEventKind>{
    TraceEventKind.pageHostMounted,
    TraceEventKind.pageHostDisposed,
    TraceEventKind.readerObservation,
    TraceEventKind.pageTransition,
    TraceEventKind.decodeDemand,
    TraceEventKind.uploadDemand,
    TraceEventKind.sourceRead,
    TraceEventKind.pageOutputReleased,
    TraceEventKind.framePresented,
    TraceEventKind.playbackFrameDue,
    TraceEventKind.playbackCompleted,
  };

  static const Set<TraceEventKind> _exportCoalescibleKinds =
      <TraceEventKind>{
    TraceEventKind.readerObservation,
    TraceEventKind.pageTransition,
    TraceEventKind.bytesCommitted,
    TraceEventKind.decodeStarted,
    TraceEventKind.decodeState,
    TraceEventKind.frameDecoded,
    TraceEventKind.uploadStarted,
    TraceEventKind.uploadState,
    TraceEventKind.frameUploaded,
    TraceEventKind.framePresented,
    TraceEventKind.framePipelineTiming,
    TraceEventKind.decodeRefill,
    TraceEventKind.playbackFrameDue,
  };

  static const Set<String> _exportRangeFields = <String>{
    'bytes',
    'depth',
    'target',
    'preparedDepth',
    'decodeMicros',
    'nativeDecodeMicros',
    'nativeMetadataMicros',
    'decodeDispatchMicros',
    'workerReadyMicros',
    'workerQueueMicros',
    'workerRoundTripMicros',
    'decodeLaneQueueMicros',
    'sourceWaitMicros',
    'cursorCreateMicros',
    'sourceLength',
    'sourceRevision',
    'consumedSourceRevision',
    'decodedToUploadMicros',
    'decodedLeadMicros',
    'uploadBackpressureMicros',
    'uploadLaneQueueMicros',
    'outputPrepareMicros',
    'outputReadyToPresentMicros',
    'platformQueueMicros',
    'platformUploadMicros',
    'platformOtherMicros',
    'platformRetainMicros',
    'platformBlitMicros',
    'platformScheduleMicros',
    'platformScheduleQueueMicros',
    'platformScheduleCallMicros',
    'platformReplaceMicros',
    'platformResultDispatchMicros',
    'presentationAckCreditMicros',
    'presentationVisibleAtMicros',
    'channelRoundTripMicros',
    'channelDispatchMicros',
    'fallbackDecodeMicros',
    'decodedToPresentMicros',
    'endToEndMicros',
    'dominantStageMicros',
    'uploadMicros',
    'presentMicros',
    'roundTripMicros',
    'bridgeMicros',
    'queueMicros',
    'deadlineMissMicros',
    'lateByMicros',
    'successorDepth',
    'logicalPosition',
    'velocity',
    'currentCoverage',
    'targetCoverage',
  };

  final int maxEvents;
  final int maxExportEvents;
  final List<TraceEvent> _events = <TraceEvent>[];
  final List<TraceEvent> _exportEvents = <TraceEvent>[];
  final Map<String, int> _exportBucketIndexes = <String, int>{};
  int _exportBaseIndex = 0;
  bool _enabled;
  bool _disposed = false;
  bool _notificationScheduled = false;
  int _recordedCount = 0;
  int _coalescedCount = 0;
  int _exportCoalescedCount = 0;
  int _exportDroppedCount = 0;

  bool get enabled => _enabled;
  int get recordedCount => _recordedCount;
  int get coalescedCount => _coalescedCount;
  int get exportCoalescedCount => _exportCoalescedCount;
  int get exportDroppedCount => _exportDroppedCount;
  List<TraceEvent> get events => List<TraceEvent>.unmodifiable(_events);
  List<TraceEvent> get exportEvents {
    final ordered = List<TraceEvent>.of(_exportEvents)
      ..sort((a, b) => a.monotonicMicros.compareTo(b.monotonicMicros));
    return List<TraceEvent>.unmodifiable(ordered);
  }
  Set<String> get sessionIds => Set<String>.unmodifiable(
        _exportEvents.map((event) => event.sessionId),
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
    if (_tryCoalesceExport(event)) {
      _exportCoalescedCount++;
    } else {
      _appendExport(event);
    }
    final exportOverflow = _exportEvents.length - maxExportEvents;
    if (exportOverflow > 0) {
      _exportEvents.removeRange(0, exportOverflow);
      _exportBaseIndex += exportOverflow;
      _exportDroppedCount += exportOverflow;
    }
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

  void _appendExport(TraceEvent event) {
    _exportEvents.add(event);
    final key = _exportBucketKey(event);
    if (key != null) {
      _exportBucketIndexes[key] =
          _exportBaseIndex + _exportEvents.length - 1;
    }
  }

  bool _tryCoalesceExport(TraceEvent event) {
    final key = _exportBucketKey(event);
    if (key == null) {
      return false;
    }
    final logicalIndex = _exportBucketIndexes[key];
    if (logicalIndex == null || logicalIndex < _exportBaseIndex) {
      return false;
    }
    final index = logicalIndex - _exportBaseIndex;
    if (index < 0 || index >= _exportEvents.length) {
      return false;
    }
    final prior = _exportEvents[index];
    final recordedFirst = prior.payload['firstMonotonicMicros'];
    final firstMonotonicMicros =
        recordedFirst is int ? recordedFirst : prior.monotonicMicros;
    if (event.monotonicMicros - firstMonotonicMicros >
        _exportWindowMicros(event.kind)) {
      return false;
    }
    _exportEvents[index] = _mergeExport(prior, event);
    return true;
  }

  String? _exportBucketKey(TraceEvent event) {
    if (!_exportCoalescibleKinds.contains(event.kind)) {
      return null;
    }
    final state = switch (event.kind) {
      TraceEventKind.decodeState ||
      TraceEventKind.uploadState => event.payload['state'],
      TraceEventKind.readerObservation ||
      TraceEventKind.pageTransition =>
        '${event.payload['currentIndex']}|${event.payload['targetIndex']}|'
            '${event.payload['interaction']}',
      TraceEventKind.framePipelineTiming =>
        '${event.payload['traceReason']}|${event.payload['dominantStage']}|'
            '${event.payload['role']}|${event.payload['decodedRole']}|'
            '${event.payload['uploadRole']}',
      TraceEventKind.decodeRefill =>
        '${event.payload['role']}|${event.payload['stage']}|'
            '${event.payload['sourceWake']}',
      _ => null,
    };
    return '${event.kind.name}|${event.sessionId}|'
        '${event.identityHash ?? ''}|${state ?? ''}';
  }

  int _exportWindowMicros(TraceEventKind kind) => switch (kind) {
        TraceEventKind.frameDecoded ||
        TraceEventKind.frameUploaded ||
        TraceEventKind.framePresented ||
        TraceEventKind.framePipelineTiming ||
        TraceEventKind.playbackFrameDue => _exportFrameWindowMicros,
        TraceEventKind.readerObservation ||
        TraceEventKind.pageTransition => _exportScrollWindowMicros,
        _ => _exportDefaultWindowMicros,
      };

  TraceEvent _mergeExport(TraceEvent prior, TraceEvent event) {
    final priorCount = prior.payload['coalescedCount'];
    final count = priorCount is int ? priorCount : 1;
    final payload = <String, Object?>{
      ...prior.payload,
      ...event.payload,
      'coalescedCount': count + 1,
      'firstMonotonicMicros':
          prior.payload['firstMonotonicMicros'] ?? prior.monotonicMicros,
      'lastMonotonicMicros': event.monotonicMicros,
    };
    final priorFrame = prior.payload['firstFrameIndex'] ??
        prior.payload['frame'];
    final eventFrame = event.payload['frame'];
    if (priorFrame != null) {
      payload['firstFrameIndex'] = priorFrame;
    }
    if (eventFrame != null) {
      payload['lastFrameIndex'] = eventFrame;
    }
    final priorPosition = prior.payload['firstLogicalPosition'] ??
        prior.payload['logicalPosition'];
    final eventPosition = event.payload['logicalPosition'];
    if (priorPosition != null) {
      payload['firstLogicalPosition'] = priorPosition;
    }
    if (eventPosition != null) {
      payload['lastLogicalPosition'] = eventPosition;
    }
    for (final field in _exportRangeFields) {
      final latest = event.payload[field];
      final previous = prior.payload[field];
      final label = '${field[0].toUpperCase()}${field.substring(1)}';
      final priorMin = prior.payload['min$label'];
      final priorMax = prior.payload['max$label'];
      final minCandidate =
          priorMin is num ? priorMin : previous is num ? previous : null;
      final maxCandidate =
          priorMax is num ? priorMax : previous is num ? previous : null;
      final values = <num>[];
      if (minCandidate != null) values.add(minCandidate);
      if (maxCandidate != null) values.add(maxCandidate);
      if (latest is num) values.add(latest);
      if (values.isEmpty) {
        continue;
      }
      payload['min$label'] = values.reduce(_minNumber);
      payload['max$label'] = values.reduce(_maxNumber);
    }
    return TraceEvent(
      monotonicMicros: event.monotonicMicros,
      sessionId: event.sessionId,
      kind: event.kind,
      identityHash: event.identityHash ?? prior.identityHash,
      revision: event.revision ?? prior.revision,
      epoch: event.epoch ?? prior.epoch,
      payload: payload,
    );
  }

  num _minNumber(num a, num b) => a <= b ? a : b;

  num _maxNumber(num a, num b) => a >= b ? a : b;

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
    if (_disposed ||
        (_events.isEmpty && _exportEvents.isEmpty && _recordedCount == 0)) {
      return;
    }
    _events.clear();
    _exportEvents.clear();
    _exportBucketIndexes.clear();
    _exportBaseIndex = 0;
    _recordedCount = 0;
    _coalescedCount = 0;
    _exportCoalescedCount = 0;
    _exportDroppedCount = 0;
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

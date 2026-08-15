import 'dart:collection';

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
      TraceEventKind.pageLayoutSnapshot ||
      TraceEventKind.readerFrameTiming ||
      TraceEventKind.pipelineReconcileTiming ||
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
    TraceEventKind.pageLayoutSnapshot,
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
    'visibleFraction',
    'scrollPixels',
    'viewportDimension',
    'expectedStart',
    'expectedExtent',
    'renderWidth',
    'renderHeight',
    'extentDeltaPx',
    'layoutResidualPx',
    'paintLeft',
    'paintTop',
    'paintRight',
    'paintBottom',
    'globalLeft',
    'globalTop',
    'globalRight',
    'globalBottom',
    'transformM00',
    'transformM01',
    'transformM10',
    'transformM11',
    'transformTx',
    'transformTy',
  };

  final int maxEvents;
  final int maxExportEvents;
  final ListQueue<TraceEvent> _events = ListQueue<TraceEvent>();
  final ListQueue<_TraceExportEntry> _exportEvents =
      ListQueue<_TraceExportEntry>();
  final Map<String, _TraceExportEntry> _exportBuckets =
      <String, _TraceExportEntry>{};
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
    final ordered = _exportEvents.map((entry) => entry.event).toList()
      ..sort((a, b) => a.monotonicMicros.compareTo(b.monotonicMicros));
    return List<TraceEvent>.unmodifiable(ordered);
  }
  Set<String> get sessionIds => Set<String>.unmodifiable(
        _exportEvents.map((entry) => entry.event.sessionId),
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
    if (_tryCoalesce(event)) {
      _coalescedCount++;
    } else {
      _events.addLast(event);
    }
    if (_events.length > maxEvents) {
      _events.removeFirst();
    }
    // FrameTiming is emitted after a rendered frame. Scheduling another UI
    // frame just to notify the trace viewer would make the diagnostic feed
    // self-sustaining and perturb the very cadence it measures. The export
    // still records every sample; ordinary trace activity refreshes the UI.
    if (event.kind != TraceEventKind.readerFrameTiming &&
        event.kind != TraceEventKind.pipelineReconcileTiming) {
      _scheduleNotification();
    }
  }

  void _appendExport(TraceEvent event) {
    final key = _exportBucketKey(event);
    final entry = _TraceExportEntry(event: event, bucketKey: key);
    _exportEvents.addLast(entry);
    if (key != null) {
      _exportBuckets[key] = entry;
    }
    if (_exportEvents.length > maxExportEvents) {
      final removed = _exportEvents.removeFirst();
      final removedKey = removed.bucketKey;
      if (removedKey != null &&
          identical(_exportBuckets[removedKey], removed)) {
        _exportBuckets.remove(removedKey);
      }
      _exportDroppedCount++;
    }
  }

  bool _tryCoalesceExport(TraceEvent event) {
    final key = _exportBucketKey(event);
    if (key == null) {
      return false;
    }
    final entry = _exportBuckets[key];
    if (entry == null) return false;
    final prior = entry.event;
    final recordedFirst = prior.payload['firstMonotonicMicros'];
    final firstMonotonicMicros =
        recordedFirst is int ? recordedFirst : prior.monotonicMicros;
    if (event.monotonicMicros - firstMonotonicMicros >
        _exportWindowMicros(event.kind)) {
      return false;
    }
    entry.event = _mergeExport(prior, event);
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
      TraceEventKind.pageLayoutSnapshot =>
        '${event.payload['pageIndex']}|${event.payload['role']}|'
            '${event.payload['interaction']}',
      TraceEventKind.framePipelineTiming =>
        '${event.payload['traceReason']}|${event.payload['dominantStage']}|'
            '${event.payload['role']}|${event.payload['decodedRole']}|'
            '${event.payload['uploadRole']}|'
            '${event.payload['platformResidentReuse']}',
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
        TraceEventKind.pageTransition ||
        TraceEventKind.pageLayoutSnapshot => _exportScrollWindowMicros,
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
    for (final entry in event.payload.entries) {
      final field = entry.key;
      final latest = entry.value;
      if (latest is! num || !_exportRangeFields.contains(field)) {
        continue;
      }
      final previous = prior.payload[field];
      final label = '${field[0].toUpperCase()}${field.substring(1)}';
      final priorMin = prior.payload['min$label'];
      final priorMax = prior.payload['max$label'];
      final minimum = priorMin is num
          ? _minNumber(priorMin, latest)
          : previous is num
              ? _minNumber(previous, latest)
              : latest;
      final maximum = priorMax is num
          ? _maxNumber(priorMax, latest)
          : previous is num
              ? _maxNumber(previous, latest)
              : latest;
      payload['min$label'] = minimum;
      payload['max$label'] = maximum;
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
    _events.removeLast();
    _events.addLast(TraceEvent(
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
    ));
    return true;
  }

  void clear() {
    if (_disposed ||
        (_events.isEmpty && _exportEvents.isEmpty && _recordedCount == 0)) {
      return;
    }
    _events.clear();
    _exportEvents.clear();
    _exportBuckets.clear();
    _recordedCount = 0;
    _coalescedCount = 0;
    _exportCoalescedCount = 0;
    _exportDroppedCount = 0;
    _scheduleNotification();
  }

  void _scheduleNotification() {
    if (_disposed || _notificationScheduled || !hasListeners) return;
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

final class _TraceExportEntry {
  _TraceExportEntry({required this.event, required this.bucketKey});

  TraceEvent event;
  final String? bucketKey;
}

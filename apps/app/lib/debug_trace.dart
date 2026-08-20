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
      TraceEventKind.staticFlutterPresentation ||
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
  static const int _readerFrameTimingBudgetMicros = 16667;
  static const int _readerFrameTimingMissedVsyncMicros = 20000;
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
    TraceEventKind.readerFrameTiming,
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
    'buildMicros',
    'rasterMicros',
    'totalSpanMicros',
    'vsyncOverheadMicros',
    'frameIntervalMicros',
    'scrollPixelsAtCallback',
    'logicalPositionAtCallback',
    'scrollVelocityAtCallback',
    'scrollSampleAgeMicros',
    'layoutGlobalTopAtCallback',
    'layoutGlobalBottomAtCallback',
    'layoutSampleAgeMicros',
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
  int get exportEventCount => _exportEvents.length;
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
    final healthyFrameTiming = _isHealthyReaderFrameTiming(event);
    if (event.kind == TraceEventKind.readerFrameTiming && !healthyFrameTiming) {
      _forgetReaderFrameTimingBucket(event);
    }
    if (_tryCoalesceExport(event)) {
      _exportCoalescedCount++;
    } else {
      _appendExport(event);
    }
    final retainInUi = event.kind != TraceEventKind.readerFrameTiming ||
        !healthyFrameTiming;
    if (!retainInUi) {
      return;
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
    // self-sustaining and perturb the very cadence it measures. Ordinary
    // trace activity refreshes the UI; healthy frame timing is export-only.
    if (event.kind != TraceEventKind.readerFrameTiming &&
        event.kind != TraceEventKind.pipelineReconcileTiming &&
        event.kind != TraceEventKind.scrollCadenceOutlier &&
        event.kind != TraceEventKind.scrollCadenceSummary &&
        event.kind != TraceEventKind.verticalSceneMotionOutlier &&
        event.kind != TraceEventKind.verticalSceneMotionSummary &&
        event.kind != TraceEventKind.platformFrameCadenceOutlier &&
        event.kind != TraceEventKind.platformFrameCadenceSummary &&
        event.kind != TraceEventKind.platformWindowFrameMetricsOutlier &&
        event.kind != TraceEventKind.platformWindowFrameMetricsSummary &&
        event.kind != TraceEventKind.platformFrameRatePolicy) {
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
    if (event.kind == TraceEventKind.readerFrameTiming &&
        !_isHealthyReaderFrameTiming(event)) {
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
      TraceEventKind.readerFrameTiming => 'healthy',
      _ => null,
    };
    return '${event.kind.name}|${event.sessionId}|'
        '${event.identityHash ?? ''}|${state ?? ''}';
  }

  bool _isHealthyReaderFrameTiming(TraceEvent event) {
    if (event.kind != TraceEventKind.readerFrameTiming) return false;
    final payload = event.payload;
    bool below(String field, String maximumField, int limit) {
      final value = payload[maximumField] ?? payload[field];
      return value is num && value < limit;
    }

    final buildHealthy =
        below('buildMicros', 'maxBuildMicros', _readerFrameTimingBudgetMicros);
    final rasterHealthy = below(
      'rasterMicros',
      'maxRasterMicros',
      _readerFrameTimingBudgetMicros,
    );
    final totalHealthy = below(
      'totalSpanMicros',
      'maxTotalSpanMicros',
      _readerFrameTimingBudgetMicros,
    );
    final interval = payload['maxFrameIntervalMicros'] ??
        payload['frameIntervalMicros'];
    final intervalHealthy = interval == null ||
        interval is num && interval < _readerFrameTimingMissedVsyncMicros;
    return buildHealthy && rasterHealthy && totalHealthy && intervalHealthy;
  }

  void _forgetReaderFrameTimingBucket(TraceEvent event) {
    final key =
        '${TraceEventKind.readerFrameTiming.name}|${event.sessionId}|'
        '${event.identityHash ?? ''}|healthy';
    _exportBuckets.remove(key);
  }

  int _exportWindowMicros(TraceEventKind kind) => switch (kind) {
        TraceEventKind.frameDecoded ||
        TraceEventKind.frameUploaded ||
        TraceEventKind.framePresented ||
        TraceEventKind.framePipelineTiming ||
        TraceEventKind.playbackFrameDue ||
        TraceEventKind.readerFrameTiming => _exportFrameWindowMicros,
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
    if (event.kind == TraceEventKind.readerFrameTiming) {
      final priorSamples = prior.payload['frameSampleCount'];
      final eventSamples = event.payload['frameSampleCount'];
      if (priorSamples is num && eventSamples is num) {
        payload['frameSampleCount'] = priorSamples + eventSamples;
      }
      final firstVsync = prior.payload['firstVsyncStartMicros'] ??
          prior.payload['vsyncStartMicros'];
      final lastVsync = event.payload['lastVsyncStartMicros'] ??
          event.payload['vsyncStartMicros'];
      if (firstVsync != null) payload['firstVsyncStartMicros'] = firstVsync;
      if (lastVsync != null) payload['lastVsyncStartMicros'] = lastVsync;
      void preserveRange(String field) {
        final label = '${field[0].toUpperCase()}${field.substring(1)}';
        final priorValue = prior.payload['max$label'] ?? prior.payload[field];
        final eventValue = event.payload['max$label'] ?? event.payload[field];
        if (priorValue is num && eventValue is num) {
          payload['max$label'] = _maxNumber(priorValue, eventValue);
        }
        final priorMinimum =
            prior.payload['min$label'] ?? prior.payload[field];
        final eventMinimum =
            event.payload['min$label'] ?? event.payload[field];
        if (priorMinimum is num && eventMinimum is num) {
          payload['min$label'] = _minNumber(priorMinimum, eventMinimum);
        }
      }

      preserveRange('buildMicros');
      preserveRange('rasterMicros');
      preserveRange('totalSpanMicros');
      preserveRange('vsyncOverheadMicros');
      preserveRange('frameIntervalMicros');
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
      final payloadMin = payload['min$label'];
      final payloadMax = payload['max$label'];
      final priorPayloadMin = prior.payload['min$label'];
      final priorPayloadMax = prior.payload['max$label'];
      final priorMin = payloadMin is num && priorPayloadMin is num
          ? _minNumber(payloadMin, priorPayloadMin)
          : payloadMin ?? priorPayloadMin;
      final priorMax = payloadMax is num && priorPayloadMax is num
          ? _maxNumber(payloadMax, priorPayloadMax)
          : payloadMax ?? priorPayloadMax;
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

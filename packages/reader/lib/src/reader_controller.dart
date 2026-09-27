import 'dart:async';

import 'package:domain/domain.dart';
import 'package:flutter/foundation.dart';
import 'package:telemetry/telemetry.dart';

final class ReaderController extends ChangeNotifier {
  ReaderController({
    required this.sessionId,
    required this.chapter,
    required ReaderObsCallback onObservation,
    required MonoClock clock,
    TraceSink traceSink = const NoopTraceSink(),
    int initialPage = 0,
  })  : assert(initialPage >= 0 && initialPage < chapter.pages.length),
        _onObservation = onObservation,
        _clock = clock,
        _traceSink = traceSink,
        _currentIndex = initialPage,
        _currentIndexNotifier = ValueNotifier<int>(initialPage),
        _stableIndex = initialPage,
        _direction = chapter.readingDirection;

  final String sessionId;
  final ChapterManifest chapter;
  final ReaderObsCallback _onObservation;
  final MonoClock _clock;
  final TraceSink _traceSink;

  int _currentIndex;
  final ValueNotifier<int> _currentIndexNotifier;
  int _stableIndex;
  ReadingDirection _direction;
  int? _requestedIndex;
  bool _requestedPageAnimated = false;
  static const Duration _scrubDispatchInterval = Duration(milliseconds: 50);

  bool _pageScrubbing = false;
  Timer? _scrubDispatchTimer;
  int? _pendingScrubIndex;
  int _navigationRevision = 0;
  int _rotationQuarterTurns = 0;
  ReaderObs? _lastObservation;
  int _lastObservationTraceMicros = -1000000;
  int? _lastTracedCurrentIndex;
  int? _lastTracedStableIndex;
  int? _lastTracedTargetIndex;
  Interaction? _lastTracedInteraction;
  List<int> _lastTracedVisibleIndexes = const <int>[];

  int get currentIndex => _currentIndex;
  ValueListenable<int> get currentIndexListenable => _currentIndexNotifier;
  int get stableIndex => _stableIndex;
  ReadingDirection get direction => _direction;
  int? get requestedIndex => _requestedIndex;
  bool get requestedPageAnimated => _requestedPageAnimated;
  bool get pageScrubbing => _pageScrubbing;
  int get navigationRevision => _navigationRevision;
  int get rotationQuarterTurns => _rotationQuarterTurns;
  ReaderObs? get lastObservation => _lastObservation;

  void setDirection(ReadingDirection value) {
    if (_direction == value) {
      return;
    }
    _direction = value;
    notifyListeners();
  }

  void rotateClockwise() {
    _rotationQuarterTurns = (_rotationQuarterTurns + 1) % 4;
    notifyListeners();
  }

  void resetRotation() {
    if (_rotationQuarterTurns == 0) {
      return;
    }
    _rotationQuarterTurns = 0;
    notifyListeners();
  }

  void requestPage(int index, {bool animated = false}) {
    _cancelScrubDispatch();
    _pageScrubbing = false;
    _requestPage(index, forceRevision: false, animated: animated);
  }

  void beginPageScrub() {
    _cancelScrubDispatch();
    _pageScrubbing = true;
  }

  void scrubToPage(int index) {
    _pageScrubbing = true;
    if (_scrubDispatchTimer != null) {
      _pendingScrubIndex = index;
      return;
    }
    _dispatchScrubPage(index);
  }

  void _dispatchScrubPage(int index) {
    _pendingScrubIndex = null;
    _requestPage(index, forceRevision: false, animated: false);
    _scrubDispatchTimer = Timer(_scrubDispatchInterval, () {
      _scrubDispatchTimer = null;
      if (!_pageScrubbing) {
        _pendingScrubIndex = null;
        return;
      }
      final pending = _pendingScrubIndex;
      if (pending != null) {
        _dispatchScrubPage(pending);
      }
    });
  }

  void endPageScrub(int index) {
    _cancelScrubDispatch();
    _pageScrubbing = false;
    // Ending a scrub is a planning boundary even when ReaderView has already
    // acknowledged the final visible page. Force one navigation revision so
    // the view can publish a non-scrub observation and restore the normal
    // encoded/decode/upload windows without another page jump.
    _requestPage(index, forceRevision: true, animated: false);
  }

  void _cancelScrubDispatch() {
    _scrubDispatchTimer?.cancel();
    _scrubDispatchTimer = null;
    _pendingScrubIndex = null;
  }

  void _requestPage(
    int index, {
    required bool forceRevision,
    required bool animated,
  }) {
    if (index < 0 || index >= chapter.pages.length) {
      throw RangeError.range(index, 0, chapter.pages.length - 1, 'index');
    }
    if (_currentIndex == index) {
      if (_requestedIndex == null && !forceRevision) {
        return;
      }
      _requestedIndex = null;
      _requestedPageAnimated = false;
      _navigationRevision++;
      notifyListeners();
      return;
    }
    if (_requestedIndex == index && !forceRevision) {
      return;
    }
    _requestedIndex = index;
    _requestedPageAnimated = animated;
    _navigationRevision++;
    notifyListeners();
  }

  void acknowledgePageRequest(int revision) {
    if (revision != _navigationRevision || _requestedIndex == null) {
      return;
    }
    _requestedIndex = null;
    _requestedPageAnimated = false;
  }

  void report(ReaderObs observation) {
    if (observation.sessionId != sessionId) {
      throw StateError('observation belongs to another reader session');
    }
    final currentIndexChanged = _currentIndex != observation.currentIndex;
    _lastObservation = observation;
    _currentIndex = observation.currentIndex;
    _stableIndex = observation.stableIndex;
    if (currentIndexChanged) {
      // Current-page projection is high-frequency Reader state, not a
      // navigation/rotation command. Keep it off the broad ChangeNotifier so
      // page shells and controls can subscribe only to the fact they need.
      _currentIndexNotifier.value = _currentIndex;
    }
    if (_shouldTraceObservation(observation)) {
      final visibleIndexes = observation.visibleCoverages
          .map((coverage) => coverage.pageIndex)
          .toList(growable: false);
      _traceSink.record(
        traceEvent(
          clock: _clock,
          sessionId: sessionId,
          kind: TraceEventKind.readerObservation,
          payload: <String, Object?>{
            'currentIndex': observation.currentIndex,
            'stableIndex': observation.stableIndex,
            'interaction': observation.interaction.name,
            'logicalPosition': observation.logicalPosition,
            'velocity': observation.velocity,
            'targetIndex': observation.targetCoverage?.pageIndex,
            'visibleIndexes': visibleIndexes,
          },
        ),
      );
      _lastObservationTraceMicros = observation.monotonicMicros;
      _lastTracedCurrentIndex = observation.currentIndex;
      _lastTracedStableIndex = observation.stableIndex;
      _lastTracedTargetIndex = observation.targetCoverage?.pageIndex;
      _lastTracedInteraction = observation.interaction;
      _lastTracedVisibleIndexes = visibleIndexes;
    }
    try {
      _onObservation(observation);
    } on Object catch (error, stackTrace) {
      // Reader navigation/presentation owns the visible page state. A pipeline
      // observation consumer may report an error, but it must never unwind a
      // ScrollNotification or page-request acknowledgement back into the UI.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'reader',
          context: ErrorDescription('while publishing a Reader observation'),
        ),
      );
    }
  }
  bool _shouldTraceObservation(ReaderObs observation) {
    if (observation.monotonicMicros - _lastObservationTraceMicros >= 250000 ||
        _lastTracedCurrentIndex != observation.currentIndex ||
        _lastTracedStableIndex != observation.stableIndex ||
        _lastTracedTargetIndex != observation.targetCoverage?.pageIndex ||
        _lastTracedInteraction != observation.interaction ||
        _lastTracedVisibleIndexes.length != observation.visibleCoverages.length) {
      return true;
    }
    for (var index = 0; index < _lastTracedVisibleIndexes.length; index++) {
      if (_lastTracedVisibleIndexes[index] !=
          observation.visibleCoverages[index].pageIndex) {
        return true;
      }
    }
    return false;
  }

  @override
  void dispose() {
    _cancelScrubDispatch();
    _currentIndexNotifier.dispose();
    super.dispose();
  }
}

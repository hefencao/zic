import 'package:flutter/foundation.dart';
import 'package:domain/domain.dart';
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
        _stableIndex = initialPage,
        _direction = chapter.readingDirection;

  final String sessionId;
  final ChapterManifest chapter;
  final ReaderObsCallback _onObservation;
  final MonoClock _clock;
  final TraceSink _traceSink;

  int _currentIndex;
  int _stableIndex;
  ReadingDirection _direction;

  int get currentIndex => _currentIndex;
  int get stableIndex => _stableIndex;
  ReadingDirection get direction => _direction;

  void setDirection(ReadingDirection value) {
    if (_direction == value) {
      return;
    }
    _direction = value;
    notifyListeners();
  }

  void report(ReaderObs observation) {
    if (observation.sessionId != sessionId) {
      throw StateError('observation belongs to another reader session');
    }
    final visibleStateChanged =
        _currentIndex != observation.currentIndex ||
        _stableIndex != observation.stableIndex;
    _currentIndex = observation.currentIndex;
    _stableIndex = observation.stableIndex;
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
        },
      ),
    );
    _onObservation(observation);
    if (visibleStateChanged) {
      notifyListeners();
    }
  }
}

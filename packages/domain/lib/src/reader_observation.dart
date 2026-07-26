import 'models.dart';

enum Interaction { idle, dragging, scrolling, jumping, settling }

final class Coverage {
  Coverage({
    required this.pageIndex,
    required this.assetKey,
    required this.fraction,
  })  : assert(pageIndex >= 0),
        assert(fraction >= 0 && fraction <= 1);

  final int pageIndex;
  final String assetKey;
  final double fraction;
}

final class ReaderObs {
  ReaderObs({
    required this.sessionId,
    required this.currentIndex,
    required this.stableIndex,
    required this.interaction,
    required this.logicalPosition,
    required this.velocity,
    required this.currentCoverage,
    required this.direction,
    required this.timestamp,
    required this.monotonicMicros,
    this.targetCoverage,
  })  : assert(currentIndex >= 0),
        assert(stableIndex >= 0);

  final String sessionId;
  final int currentIndex;
  final int stableIndex;
  final Interaction interaction;
  final double logicalPosition;
  final double velocity;
  final Coverage currentCoverage;
  final Coverage? targetCoverage;
  final ReadingDirection direction;
  final DateTime timestamp;
  final int monotonicMicros;
}

typedef ReaderObsCallback = void Function(ReaderObs observation);

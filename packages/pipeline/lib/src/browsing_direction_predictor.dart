import 'dart:math' as math;

/// Stateful browsing-direction evidence owned by the Pipeline policy plane.
///
/// Page indexes are storage/navigation identities; they do not by themselves
/// say which side of the current page is the user's likely forward-reading
/// side. A single opposite movement is therefore only a candidate reversal.
/// Sustained opposite movement or a sufficiently strong weighted trend flips
/// [direction]. Scrubs and large jumps do not teach direction.
final class BrowsingDirectionPredictor {
  BrowsingDirectionPredictor({int initialDirection = 1})
      : _direction = initialDirection < 0 ? -1 : 1;

  static const int _maxHistory = 12;
  static const int _shortDwellMicros = 400000;
  static const int _mediumDwellMicros = 2000000;
  static const double _decayFactor = 0.85;
  static const int _maxDirectionalDelta = 5;

  int _direction;
  int _candidateDirection = 0;
  int _candidateCount = 0;
  int? _lastChangeMicros;
  final List<_DirectionSample> _history = <_DirectionSample>[];

  int get direction => _direction;

  void reset({int direction = 1, int? nowMicros}) {
    _direction = direction < 0 ? -1 : 1;
    _candidateDirection = 0;
    _candidateCount = 0;
    _lastChangeMicros = nowMicros;
    _history.clear();
  }

  int record({
    required int delta,
    required int nowMicros,
    bool directional = true,
  }) {
    if (!directional || delta == 0 || delta.abs() > _maxDirectionalDelta) {
      _candidateDirection = 0;
      _candidateCount = 0;
      _lastChangeMicros = nowMicros;
      return _direction;
    }

    final dwellMicros = _lastChangeMicros == null
        ? 0
        : (nowMicros - _lastChangeMicros!).clamp(0, 10000000).toInt();
    _lastChangeMicros = nowMicros;
    final movement = delta < 0 ? -1 : 1;
    final baseWeight = dwellMicros >= _mediumDwellMicros
        ? 4
        : dwellMicros >= _shortDwellMicros
            ? 2
            : 1;
    _history.add(_DirectionSample(movement, baseWeight));
    if (_history.length > _maxHistory) _history.removeAt(0);
    _applyDecay();

    if (movement == _direction) {
      _candidateDirection = 0;
      _candidateCount = 0;
    } else {
      if (_candidateDirection == movement) {
        _candidateCount++;
      } else {
        _candidateDirection = movement;
        _candidateCount = 1;
      }
      if (_candidateCount >= 2) {
        _direction = movement;
        _candidateDirection = 0;
        _candidateCount = 0;
        return _direction;
      }
    }

    var trend = 0;
    var totalWeight = 0;
    for (final sample in _history) {
      trend += sample.direction * sample.weight;
      totalWeight += sample.weight;
    }
    final threshold = (totalWeight / 3).ceil().clamp(3, 6).toInt();
    if (trend.abs() >= threshold) {
      final predicted = trend < 0 ? -1 : 1;
      if (predicted != _direction) {
        _direction = predicted;
        _candidateDirection = 0;
        _candidateCount = 0;
      }
    }
    return _direction;
  }

  void _applyDecay() {
    for (var i = 0; i < _history.length; i++) {
      final age = _history.length - 1 - i;
      final weight = (_history[i].weight * math.pow(_decayFactor, age))
          .round()
          .clamp(1, 5)
          .toInt();
      _history[i] = _DirectionSample(_history[i].direction, weight);
    }
  }
}

final class _DirectionSample {
  const _DirectionSample(this.direction, this.weight);

  final int direction;
  final int weight;
}

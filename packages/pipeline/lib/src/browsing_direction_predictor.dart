/// Stable committed-page browsing intent owned by the Pipeline policy plane.
///
/// The 3/7 window is asymmetric, so changing its orientation is a material
/// working-set change. One reverse page is treated as a local revisit, not as
/// proof that the user's browsing direction changed. Only a second committed
/// page move in the same opposite direction confirms the reversal. Scrubs,
/// jumps and other non-directional observations clear the candidate so a
/// stale gesture cannot flip a later window.
final class BrowsingDirectionPredictor {
  BrowsingDirectionPredictor({int initialDirection = 1})
      : _direction = initialDirection < 0 ? -1 : 1;

  int _direction;
  int _candidateDirection = 0;
  int _candidateCount = 0;

  int get direction => _direction;
  int get candidateDirection => _candidateDirection;
  int get candidateCount => _candidateCount;

  void reset({int direction = 1}) {
    _direction = direction < 0 ? -1 : 1;
    _candidateDirection = 0;
    _candidateCount = 0;
  }

  int record({
    required int delta,
    bool directional = true,
  }) {
    if (!directional || delta == 0 || delta.abs() > 5) {
      _candidateDirection = 0;
      _candidateCount = 0;
      return _direction;
    }

    final movement = delta < 0 ? -1 : 1;
    if (movement == _direction) {
      _candidateDirection = 0;
      _candidateCount = 0;
      return _direction;
    }

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
    }
    return _direction;
  }
}

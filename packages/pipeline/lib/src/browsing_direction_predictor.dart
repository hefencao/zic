/// Stable committed-page prefetch intent owned by the Pipeline policy plane.
///
/// Reader current/visible/transition state follows every observation immediately.
/// This predictor owns only the orientation of asymmetric working-set policy
/// (the 3/7 encoded window and dependent warm roles). A local reverse traversal
/// must therefore not turn every page seam into a whole-window migration.
///
/// Reversal is committed only after four cumulative committed-page steps in
/// the opposite direction. Forward movement in the existing direction clears
/// the candidate. Scrubs, jumps and other non-directional observations clear
/// it too, so stale gesture evidence cannot flip a later working set.
final class BrowsingDirectionPredictor {
  BrowsingDirectionPredictor({int initialDirection = 1})
      : _direction = initialDirection < 0 ? -1 : 1;

  static const int reversalDistancePages = 4;

  int _direction;
  int _candidateDirection = 0;
  int _candidateDistance = 0;

  int get direction => _direction;
  int get candidateDirection => _candidateDirection;
  int get candidateDistance => _candidateDistance;
  int get candidateCount => _candidateDistance;

  void reset({int direction = 1}) {
    _direction = direction < 0 ? -1 : 1;
    _clearCandidate();
  }

  int record({
    required int delta,
    bool directional = true,
  }) {
    if (!directional || delta == 0 || delta.abs() > 5) {
      _clearCandidate();
      return _direction;
    }

    final movement = delta < 0 ? -1 : 1;
    if (movement == _direction) {
      _clearCandidate();
      return _direction;
    }

    if (_candidateDirection != movement) {
      _candidateDirection = movement;
      _candidateDistance = 0;
    }
    _candidateDistance += delta.abs();
    if (_candidateDistance >= reversalDistancePages) {
      _direction = movement;
      _clearCandidate();
    }
    return _direction;
  }

  void _clearCandidate() {
    _candidateDirection = 0;
    _candidateDistance = 0;
  }
}

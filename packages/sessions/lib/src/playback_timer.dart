enum PlaybackState { idle, running, frozen }

final class PlaybackTimer {
  PlaybackState _state = PlaybackState.idle;
  int? _frameIndex;
  int _deadlineUs = 0;
  int _remainingUs = 0;

  PlaybackState get state => _state;
  int? get frameIndex => _frameIndex;
  bool get active => _state != PlaybackState.idle;

  int remainingUs(int nowUs) {
    switch (_state) {
      case PlaybackState.idle:
        return 0;
      case PlaybackState.frozen:
        return _remainingUs;
      case PlaybackState.running:
        final remaining = _deadlineUs - nowUs;
        return remaining > 0 ? remaining : 0;
    }
  }

  void start({
    required int frameIndex,
    required Duration duration,
    required int nowUs,
  }) {
    final micros = duration.inMicroseconds;
    _frameIndex = frameIndex;
    _remainingUs = micros > 0 ? micros : 0;
    _deadlineUs = nowUs + _remainingUs;
    _state = PlaybackState.running;
  }

  bool freeze(int nowUs) {
    if (_state != PlaybackState.running) {
      return false;
    }
    _remainingUs = remainingUs(nowUs);
    _state = PlaybackState.frozen;
    return true;
  }

  bool resume(int nowUs) {
    if (_state != PlaybackState.frozen) {
      return false;
    }
    _deadlineUs = nowUs + _remainingUs;
    _state = PlaybackState.running;
    return true;
  }

  int? takeDue(int nowUs) {
    if (_state != PlaybackState.running || nowUs < _deadlineUs) {
      return null;
    }
    final due = _frameIndex;
    clear();
    return due;
  }

  void clear() {
    _state = PlaybackState.idle;
    _frameIndex = null;
    _deadlineUs = 0;
    _remainingUs = 0;
  }
}

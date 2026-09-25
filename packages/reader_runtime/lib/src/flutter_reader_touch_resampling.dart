import 'package:flutter/gestures.dart';

/// Process-global Flutter touch-resampling lease owned by ReaderRuntime.
///
/// A vertical Reader may acquire this lease while it owns continuous touch
/// scrolling. The first lease preserves the pre-existing framework setting;
/// the final release restores it. Reader presentation itself never mutates
/// [GestureBinding].
final class FlutterReaderTouchResamplingLease {
  FlutterReaderTouchResamplingLease._();

  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    FlutterReaderTouchResampling._release();
  }
}

final class FlutterReaderTouchResampling {
  FlutterReaderTouchResampling._();

  static int _leases = 0;
  static bool? _restoreEnabled;

  static FlutterReaderTouchResamplingLease acquire() {
    final binding = GestureBinding.instance;
    if (_leases == 0) {
      _restoreEnabled = binding.resamplingEnabled;
      binding.resamplingEnabled = true;
    }
    _leases++;
    return FlutterReaderTouchResamplingLease._();
  }

  static void _release() {
    if (_leases <= 0) return;
    _leases--;
    if (_leases != 0) return;
    final restoreEnabled = _restoreEnabled;
    _restoreEnabled = null;
    if (restoreEnabled != null) {
      GestureBinding.instance.resamplingEnabled = restoreEnabled;
    }
  }
}

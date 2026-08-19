import 'package:flutter/gestures.dart';

/// Scoped owner for Flutter touch-event resampling while a continuous Reader
/// is mounted.
///
/// GestureBinding is process-global, so ReaderRuntime owns a ref-counted lease
/// instead of letting Reader presentation mutate framework input state.
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

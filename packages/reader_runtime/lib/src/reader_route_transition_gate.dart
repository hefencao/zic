import 'package:flutter/material.dart';

/// Defers one route-owned side effect until the route's entering transition
/// has completed. A user interaction can explicitly commit it earlier.
final class ReaderRouteTransitionGate {
  ReaderRouteTransitionGate(this._apply);

  final VoidCallback _apply;
  Animation<double>? _animation;
  AnimationStatusListener? _listener;
  bool _probeScheduled = false;
  bool _applied = false;
  bool _disposed = false;

  void schedule(BuildContext context) {
    if (_disposed || _applied || _listener != null || _probeScheduled) return;
    _probeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _probeScheduled = false;
      if (_disposed || _applied || _listener != null || !context.mounted) return;
      final animation = ModalRoute.of(context)?.animation;
      if (animation == null || animation.status == AnimationStatus.completed) {
        _commit();
        return;
      }
      late AnimationStatusListener listener;
      listener = (status) {
        if (status != AnimationStatus.completed) return;
        animation.removeStatusListener(listener);
        if (identical(_listener, listener)) {
          _listener = null;
          _animation = null;
        }
        _commit();
      };
      _animation = animation;
      _listener = listener;
      animation.addStatusListener(listener);
      if (animation.status == AnimationStatus.completed) {
        listener(AnimationStatus.completed);
      }
    });
  }

  void applyNow() {
    if (_disposed || _applied) return;
    _cancelListener();
    _commit();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelListener();
  }

  void _cancelListener() {
    final animation = _animation;
    final listener = _listener;
    if (animation != null && listener != null) {
      animation.removeStatusListener(listener);
    }
    _animation = null;
    _listener = null;
  }

  void _commit() {
    if (_disposed || _applied) return;
    _applied = true;
    _apply();
  }
}

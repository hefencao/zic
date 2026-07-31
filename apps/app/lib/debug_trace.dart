import 'package:flutter/foundation.dart';
import 'package:telemetry/telemetry.dart';

/// Bounded UI projection of trace events.
///
/// Trace producers keep their existing ownership. This class is only a sink
/// and observable read model for the debug surface.
final class DebugTraceLog extends ChangeNotifier implements TraceSink {
  DebugTraceLog({this.maxEvents = 500, bool enabled = true})
      : assert(maxEvents > 0),
        _enabled = enabled;

  final int maxEvents;
  final List<TraceEvent> _events = <TraceEvent>[];
  bool _enabled;
  bool _disposed = false;

  bool get enabled => _enabled;
  List<TraceEvent> get events => List<TraceEvent>.unmodifiable(_events);

  set enabled(bool value) {
    if (_disposed || _enabled == value) return;
    _enabled = value;
    notifyListeners();
  }

  @override
  void record(TraceEvent event) {
    if (_disposed || !_enabled) return;
    _events.add(event);
    final overflow = _events.length - maxEvents;
    if (overflow > 0) {
      _events.removeRange(0, overflow);
    }
    notifyListeners();
  }

  void clear() {
    if (_disposed || _events.isEmpty) return;
    _events.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}


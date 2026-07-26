import 'package:telemetry/telemetry.dart';

final class FakeMonoClock implements MonoClock {
  FakeMonoClock({int initialMicros = 0}) : _micros = initialMicros;

  int _micros;

  @override
  int nowMicros() => _micros;

  void advance(Duration duration) {
    if (duration.isNegative) {
      throw ArgumentError.value(duration, 'duration', 'must be non-negative');
    }
    _micros += duration.inMicroseconds;
  }

  void setMicros(int value) {
    if (value < _micros) {
      throw ArgumentError.value(value, 'value', 'clock cannot move backwards');
    }
    _micros = value;
  }
}

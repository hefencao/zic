abstract interface class MonoClock {
  int nowMicros();
}

/// Process-wide monotonic clock shared by every resource session.
///
/// A per-session stopwatch makes sequential Reader sessions appear to overlap
/// after debug exports sort events by timestamp. Keeping one epoch also lets
/// lifecycle telemetry prove that disposal completed before a later session
/// started.
final class SystemClock implements MonoClock {
  const SystemClock();

  static final Stopwatch _watch = Stopwatch()..start();

  @override
  int nowMicros() => _watch.elapsedMicroseconds;
}

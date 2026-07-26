abstract interface class MonoClock {
  int nowMicros();
}

final class SystemClock implements MonoClock {
  SystemClock() {
    _watch.start();
  }

  final Stopwatch _watch = Stopwatch();

  @override
  int nowMicros() => _watch.elapsedMicroseconds;
}

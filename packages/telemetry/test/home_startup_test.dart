import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

void main() {
  test('home startup trace preserves service and cover phases', () {
    final clock = _Clock();
    final sink = MemoryTraceSink();
    final telemetry = HomeStartupTelemetry(clock: clock, sink: sink);

    telemetry.servicesOpenStarted();
    final serviceStarted = telemetry.nowMicros();
    clock.advance(120);
    telemetry.serviceReady('library-store', startedAtMicros: serviceStarted);
    telemetry.bootstrapPresented();
    telemetry.coverRequested('source/comic/cover');
    clock.advance(30);
    telemetry.coverSourceReady(
      'source/comic/cover',
      source: 'durableCacheFile',
      byteLength: 4096,
    );
    clock.advance(70);
    telemetry.coverFirstFrame('source/comic/cover');

    expect(
      sink.events.map((event) => event.kind),
      <TraceEventKind>[
        TraceEventKind.homeServicesOpenStarted,
        TraceEventKind.homeServiceReady,
        TraceEventKind.homeBootstrapPresented,
        TraceEventKind.homeCoverRequested,
        TraceEventKind.homeCoverSourceReady,
        TraceEventKind.homeCoverFirstFrame,
      ],
    );
    expect(sink.events[1].payload, <String, Object?>{
      'stage': 'library-store',
      'durationMicros': 120,
    });
    expect(sink.events[4].payload, <String, Object?>{
      'source': 'durableCacheFile',
      'byteLength': 4096,
    });
  });
}

final class _Clock implements MonoClock {
  int _micros = 0;

  void advance(int micros) => _micros += micros;

  @override
  int nowMicros() => _micros;
}

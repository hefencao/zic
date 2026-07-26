import 'package:test/test.dart';
import 'package:telemetry/telemetry.dart';

final class _Clock implements MonoClock {
  @override
  int nowMicros() => 42;
}

void main() {
  test('trace uses monotonic time and serializes stable fields', () {
    final event = traceEvent(
      clock: _Clock(),
      sessionId: 's1',
      kind: TraceEventKind.policyDecision,
      revision: 3,
      payload: const <String, Object?>{'profile': 'balanced'},
    );

    expect(event.toJson()['t'], 42);
    expect(event.toJson()['revision'], 3);
  });
}

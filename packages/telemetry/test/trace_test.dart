import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

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

  test('trace replaces Venera locator payloads with compact summaries', () {
    const token =
        'venera-resource:eyJ2IjoxLCJpbWFnZSI6IjE2MSIsImNvbWljSWQiOiJsb25nLWNvbWljLWlkIn0';
    const comic =
        'venera:comic:eyJpZCI6ImxvbmcgY29taWMgaWRlbnRpdHkiLCJ0aXRsZSI6IkZpeHR1cmUifQ';
    const chapter =
        'venera:chapter:eyJjb21pY0lkIjoibG9uZy1jb21pYyIsInNlcXVlbmNlIjoxNjF9';
    final event = traceEvent(
      clock: _Clock(),
      sessionId: 'reader',
      kind: TraceEventKind.decodeDemand,
      identityHash: '$comic/$chapter/page|$token|1216x2656',
      payload: const <String, Object?>{
        'uri': token,
        'comicId': comic,
        'chapterId': chapter,
        'nested': <String, Object?>{'locator': token},
      },
    );
    final encoded = event.toJsonLine();

    expect(encoded, isNot(contains(token)));
    expect(encoded, isNot(contains(comic)));
    expect(encoded, isNot(contains(chapter)));
    expect(encoded, contains('venera-resource:<'));
    expect(encoded, contains('venera:comic:<'));
    expect(encoded, contains('venera:chapter:<'));
    expect(encoded, contains(token.length.toString()));
  });
  test('trace replaces Mihon opaque payloads with compact summaries', () {
    const manga =
        'mihon:manga:eyJ1cmwiOiJcL2Jvb2tzXC9sb25nLW1hbmdhIiwidGl0bGUiOiJGaXh0dXJlIn0';
    const chapter =
        'mihon:chapter:eyJ1cmwiOiJcL2Jvb2tzXC9sb25nLW1hbmdhXC8xIiwic2VxdWVuY2UiOjF9';
    const resource =
        'mihon:resource:eyJ1cmwiOiJodHRwczpcL1wvY2RuLmludmFsaWRcL2xvbmcuaW1hZ2UuanBnIn0';
    final encoded = traceEvent(
      clock: _Clock(),
      sessionId: 'reader',
      kind: TraceEventKind.decodeDemand,
      identityHash: '$manga/$chapter/$resource',
      payload: const <String, Object?>{'resource': resource},
    ).toJsonLine();

    expect(encoded, isNot(contains(manga)));
    expect(encoded, isNot(contains(chapter)));
    expect(encoded, isNot(contains(resource)));
    expect(encoded, contains('mihon:manga:<'));
    expect(encoded, contains('mihon:chapter:<'));
    expect(encoded, contains('mihon:resource:<'));
  });

}

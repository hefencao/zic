import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

final class _Clock implements MonoClock {
  @override
  int nowMicros() => 42;
}

enum _FixtureTraceState { ready }

final class _FixtureTraceObject {
  const _FixtureTraceObject(this.label);

  final String label;

  @override
  String toString() => 'fixture:$label';
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


  test('trace payload is normalized to JSON-safe values at record time', () {
    final event = traceEvent(
      clock: _Clock(),
      sessionId: 'json-safe',
      kind: TraceEventKind.readerObservation,
      payload: <String, Object?>{
        'enum': _FixtureTraceState.ready,
        'uri': Uri.parse('https://example.invalid/image'),
        'duration': const Duration(milliseconds: 5),
        'dateTime': DateTime.utc(2026, 9, 9, 12, 30),
        'custom': const _FixtureTraceObject('opaque'),
        'nested': <Object?, Object?>{
          7: _FixtureTraceState.ready,
          'nan': double.nan,
          'positiveInfinity': double.infinity,
          'negativeInfinity': double.negativeInfinity,
        },
      },
    );

    final encoded = event.toJsonLine();
    expect(encoded, contains(r'"enum":"ready"'));
    expect(encoded, contains('https://example.invalid/image'));
    expect(encoded, contains('0:00:00.005000'));
    expect(encoded, contains('2026-09-09T12:30:00.000Z'));
    expect(encoded, contains('fixture:opaque'));
    expect(encoded, contains(r'"7":"ready"'));
    expect(encoded, contains(r'"nan":"non-finite:NaN"'));
    expect(encoded, contains(r'"positiveInfinity":"non-finite:+Infinity"'));
    expect(encoded, contains(r'"negativeInfinity":"non-finite:-Infinity"'));
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
    expect(encoded, contains('identity:<'));
    expect(encoded, isNot(contains('mihon:manga:<')));
    expect(encoded, isNot(contains('mihon:chapter:<')));
    expect(encoded, contains('mihon:resource:<'));
  });

  test('trace identity token matches event identity sanitization', () {
    final identity = List<String>.filled(5, 'venera-resource:opaque-provider-key').join('|');
    final token = traceIdentityToken(identity);
    final event = traceEvent(
      clock: _Clock(),
      sessionId: 'reader',
      kind: TraceEventKind.decodeDemand,
      identityHash: identity,
    );

    expect(token, event.identityHash);
    expect(
      traceEvent(
        clock: _Clock(),
        sessionId: 'reader',
        kind: TraceEventKind.decodeDemand,
        identityHash: token,
      ).identityHash,
      token,
    );
  });

  test('trace composite payload keys retain raw identity correlation', () {
    final manga = 'mihon:manga:${List<String>.filled(495, 'a').join()}';
    final chapter = 'mihon:chapter:${List<String>.filled(998, 'b').join()}';
    final scope = 'content:v2${manga.length}:$manga'
        '${chapter.length}:$chapter';
    final exact = 'download:v2${scope.length}:$scope';
    final physical = 'physical-media:v1${exact.length}:$exact';
    final event = traceEvent(
      clock: _Clock(),
      sessionId: 'reader',
      kind: TraceEventKind.artifactSource,
      payload: <String, Object?>{
        'scopeId': scope,
        'providerExactId': exact,
        'physicalMediaKey': physical,
        'candidatePhysicalKeys': <String>[physical],
        'comicId': manga,
      },
    );

    expect(event.payload['scopeId'], traceIdentityToken(scope));
    expect(event.payload['providerExactId'], traceIdentityToken(exact));
    expect(event.payload['physicalMediaKey'], traceIdentityToken(physical));
    expect(event.payload['candidatePhysicalKeys'],
        <String>[traceIdentityToken(physical)]);
    expect(event.payload['comicId'], endsWith(',507>'));
    expect(event.toJsonLine(), isNot(contains(manga)));
    expect(event.toJsonLine(), isNot(contains(chapter)));
  });

  test('nested short opaque composite keys sanitize once', () {
    final manga = 'mihon:manga:${List<String>.filled(24, 'a').join()}';
    final chapter = 'mihon:chapter:${List<String>.filled(24, 'b').join()}';
    final scope = '${manga.length}:$manga${chapter.length}:$chapter';
    expect(scope.length, lessThan(160));
    final first = traceEvent(
      clock: _Clock(),
      sessionId: 'reader',
      kind: TraceEventKind.artifactSource,
      payload: <String, Object?>{
        'nested': <Object?, Object?>{
          Uri.parse('scopeId'): scope,
          'candidatePhysicalKeys': <String>[scope],
        },
        'scopeId': 'legacy',
        'count': 1,
      },
    );
    final nested = first.payload['nested']! as Map<String, Object?>;
    final token = nested['scopeId']! as String;
    expect(token, startsWith('identity:<'));
    expect(token, endsWith(',${scope.length}>'));
    expect(nested['candidatePhysicalKeys'], <String>[token]);
    expect(first.payload['scopeId'], 'legacy');
    expect(first.payload['count'], 1);
    expect(first.toJsonLine(), isNot(contains(manga)));
    final second = traceEvent(
      clock: _Clock(),
      sessionId: 'reader',
      kind: TraceEventKind.artifactSource,
      payload: first.payload,
    );
    expect(second.payload, first.payload);
  });

  test('long provider identities skip nested sanitizer expansion', () {
    const resource =
        'venera-resource:eyJ2IjoxLCJpbWFnZSI6IjE2MSIsImNvbWljSWQiOiJsb25nLWNvbWljLWlkIn0';
    final identity = List<String>.filled(4, resource).join('|');

    final event = traceEvent(
      clock: _Clock(),
      sessionId: 'reader',
      kind: TraceEventKind.demandApplied,
      identityHash: identity,
    );

    expect(event.identityHash, startsWith('identity:<'));
    expect(event.identityHash, isNot(contains('venera-resource:<')));
    expect(event.toJsonLine(), isNot(contains(resource)));
  });

  test('trace bounds long local identities without losing stable correlation', () {
    final identity =
        'local-folder/${List<String>.filled(40, 'segment').join('/')}';
    final first = traceEvent(
      clock: _Clock(),
      sessionId: 'reader',
      kind: TraceEventKind.framePresented,
      identityHash: identity,
    );
    final second = traceEvent(
      clock: _Clock(),
      sessionId: 'reader',
      kind: TraceEventKind.frameUploaded,
      identityHash: identity,
    );

    expect(first.identityHash, startsWith('identity:<'));
    expect(first.identityHash, second.identityHash);
    expect(first.identityHash!.length, lessThan(identity.length));
    expect(first.toJsonLine(), isNot(contains(identity)));
  });

  test('bounded memory trace evicts oldest events in constant-size order', () {
    final sink = MemoryTraceSink(maxEvents: 2);
    for (var index = 0; index < 3; index++) {
      sink.record(
        TraceEvent(
          monotonicMicros: index,
          sessionId: 'bounded-memory',
          kind: TraceEventKind.downloadState,
          payload: <String, Object?>{'index': index},
        ),
      );
    }

    expect(
      sink.events.map((event) => event.payload['index']),
      <int>[1, 2],
    );
    sink.clear();
    expect(sink.events, isEmpty);
  });

  test('SystemClock instances share one process monotonic epoch', () {
    const first = SystemClock();
    while (first.nowMicros() < 1000) {}
    final checkpoint = first.nowMicros();
    const second = SystemClock();

    expect(second.nowMicros(), greaterThanOrEqualTo(checkpoint));
  });

}

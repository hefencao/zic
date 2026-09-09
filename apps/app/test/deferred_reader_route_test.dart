import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry/telemetry.dart';
import 'package:zic/deferred_reader_route.dart';

void main() {
  testWidgets('Reader route renders before chapter preparation completes',
      (tester) async {
    final chapter = Completer<String>();
    await tester.pumpWidget(
      MaterialApp(
        home: DeferredReaderRoute<String>(
          title: '第 1 话',
          load: () => chapter.future,
          builder: (_, value) => Scaffold(body: Text(value)),
        ),
      ),
    );

    expect(find.byKey(deferredReaderRouteKey), findsOneWidget);
    expect(find.byKey(deferredReaderLoadingKey), findsOneWidget);
    expect(find.text('第 1 话'), findsOneWidget);

    chapter.complete('reader-ready');
    await tester.pump();

    expect(find.text('reader-ready'), findsOneWidget);
    expect(find.byKey(deferredReaderLoadingKey), findsNothing);
  });

  testWidgets('Reader load failure is traced and copyable in place', (tester) async {
    final trace = MemoryTraceSink();
    await tester.pumpWidget(
      MaterialApp(
        home: DeferredReaderRoute<String>(
          title: '第 2 话',
          traceSink: trace,
          traceSessionId: 'reader-entry-test',
          load: () => Future<String>.error(StateError('source unavailable')),
          builder: (_, value) => Text(value),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(deferredReaderErrorKey), findsOneWidget);
    expect(find.byKey(deferredReaderCopyErrorKey), findsOneWidget);
    expect(find.textContaining('source unavailable'), findsOneWidget);
    expect(trace.events, hasLength(1));
    expect(trace.events.single.kind, TraceEventKind.taskFailed);
    expect(trace.events.single.payload['stage'], 'deferred-reader-load');
  });

}

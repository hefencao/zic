import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}

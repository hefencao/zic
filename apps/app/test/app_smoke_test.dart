import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/demo_home.dart';
import 'package:zic/main.dart';
import 'package:zic/static_demo.dart';
import 'package:zic/webp_demo.dart';

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 60,
}) async {
  for (var frame = 0; frame < maxFrames; frame++) {
    await tester.pump();
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  throw TestFailure('Timed out waiting for $finder after $maxFrames frames');
}

Future<void> _pumpUntilAbsent(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 60,
}) async {
  for (var frame = 0; frame < maxFrames; frame++) {
    await tester.pump();
    if (finder.evaluate().isEmpty) {
      return;
    }
  }
  throw TestFailure('Timed out waiting for $finder to disappear');
}

void main() {
  testWidgets('home exposes product entry points by semantic identity', (tester) async {
    await tester.pumpWidget(const App());
    await tester.pump();

    expect(find.byKey(staticDemoEntryKey), findsOneWidget);
    expect(find.byKey(mediaPipelineReaderEntryKey), findsOneWidget);
    expect(find.byKey(bundledWebpEntryKey), findsOneWidget);
    expect(find.byKey(localWebpImportKey), findsOneWidget);
  });

  testWidgets('static route opens from its semantic entry', (tester) async {
    await tester.pumpWidget(const App());
    await tester.tap(find.byKey(staticDemoEntryKey));
    await tester.pumpAndSettle();

    expect(find.text('1 / 100'), findsOneWidget);
  });

  testWidgets('Reader route hosts the real WebP media pipeline', (tester) async {
    await tester.pumpWidget(const App());
    await tester.tap(find.byKey(mediaPipelineReaderEntryKey));
    await _pumpUntilFound(tester, find.byKey(readerMediaWebpPageKey));
    await _pumpUntilFound(tester, find.byKey(webpPreviewStateKey));

    WebpPreviewState? state;
    for (var frame = 0; frame < 80; frame++) {
      await tester.pump();
      final region = tester.widget<WebpPreviewStateRegion>(
        find.byKey(webpPreviewStateKey),
      );
      state = region.state;
      if (state.phase == WebpPreviewPhase.ready) {
        break;
      }
    }

    expect(state?.phase, WebpPreviewPhase.ready);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('bundled WebP catalog opens from its semantic entry', (
    tester,
  ) async {
    await tester.pumpWidget(const App());
    await tester.tap(find.byKey(bundledWebpEntryKey));
    await _pumpUntilFound(tester, find.text('无限循环 · 基础帧'));

    expect(find.text('有限循环 · 2 次'), findsOneWidget);
    expect(find.text('局部帧 · Alpha Blend'), findsOneWidget);
  });

  testWidgets('picked WebP navigates with the owned display name', (
    tester,
  ) async {
    final picked = PickedWebp(
      file: XFile('/virtual/route-source.webp'),
      displayName: 'route-owned.webp',
    );
    await tester.pumpWidget(App(picker: () async => picked));

    await tester.tap(find.byKey(localWebpImportKey));
    await _pumpUntilFound(tester, find.byKey(webpPreviewScreenKey));

    final title = tester.widget<Text>(find.byKey(webpPreviewTitleKey));
    expect(title.data, 'route-owned.webp');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('cancelled picker stays on home without opening a route', (
    tester,
  ) async {
    await tester.pumpWidget(App(picker: () async => null));

    await tester.tap(find.byKey(localWebpImportKey));
    await _pumpUntilAbsent(tester, find.byKey(localWebpPickerProgressKey));

    expect(find.byKey(webpPreviewScreenKey), findsNothing);
    expect(find.byKey(localWebpImportKey), findsOneWidget);
    expect(find.byKey(localWebpPickerProgressKey), findsNothing);
  });
}

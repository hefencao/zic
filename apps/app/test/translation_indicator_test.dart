import 'package:comic_translation/comic_translation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/translation_indicator.dart';

void main() {
  testWidgets('processing-only indicator follows page state and hides terminal output', (tester) async {
    final phase = ValueNotifier(ComicTranslationPhase.queued);
    addTearDown(phase.dispose);
    await tester.pumpWidget(MaterialApp(home: Center(child: ValueListenableBuilder<ComicTranslationPhase>(
      valueListenable: phase,
      builder: (_, value, __) => ComicTranslationIndicator(
        pageIndex: 26, phase: value, status: value.name, onlyWhileProcessing: true),
    ))));
    for (final value in [ComicTranslationPhase.queued, ComicTranslationPhase.waitingForImage, ComicTranslationPhase.loadingCache,
        ComicTranslationPhase.recognizing, ComicTranslationPhase.translating]) {
      phase.value = value;
      await tester.pump();
      expect(find.byKey(const ValueKey('reader-translation-status')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    }
    for (final value in [ComicTranslationPhase.ready, ComicTranslationPhase.failed,
        ComicTranslationPhase.unavailable, ComicTranslationPhase.unsupportedMedia, ComicTranslationPhase.disabled]) {
      phase.value = value;
      await tester.pump();
      expect(find.byKey(const ValueKey('reader-translation-status')), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    }
    phase.value = ComicTranslationPhase.recognizing;
    await tester.pump();
    expect(find.byKey(const ValueKey('reader-translation-status')), findsOneWidget,
      reason: 'new work must show the indicator again after a completed page');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('only the current stage is drawn and page numbers require Debug mode', (tester) async {
    Future<void> show(ComicTranslationPhase phase, {bool debug = false}) => tester.pumpWidget(MaterialApp(home: Center(
      child: ComicTranslationIndicator(pageIndex: 26, phase: phase, status: '当前阶段', showPageNumber: debug),
    )));
    await show(ComicTranslationPhase.recognizing);
    expect(find.byIcon(Icons.document_scanner_outlined), findsOneWidget);
    expect(find.byIcon(Icons.translate), findsNothing);
    expect(find.byType(Icon), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-translation-ocr-progress')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-translation-translation-progress')), findsNothing);
    expect(find.text('当前阶段'), findsNothing);
    expect(find.text('27'), findsNothing);
    expect(find.bySemanticsLabel('当前阶段'), findsOneWidget);
    await show(ComicTranslationPhase.translating);
    expect(find.byIcon(Icons.document_scanner_outlined), findsNothing);
    expect(find.byIcon(Icons.translate), findsOneWidget);
    expect(find.byType(Icon), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-translation-ocr-progress')), findsNothing);
    expect(find.byKey(const ValueKey('reader-translation-translation-progress')), findsOneWidget);
    await show(ComicTranslationPhase.translating, debug: true);
    expect(find.text('27'), findsOneWidget);
    expect(find.bySemanticsLabel('第27页，当前阶段'), findsOneWidget);
    await show(ComicTranslationPhase.ready);
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.byType(Icon), findsOneWidget);
    expect(find.text('27'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(const ValueKey('reader-translation-status')), findsOneWidget);
    await show(ComicTranslationPhase.failed);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

import 'dart:io';

import 'package:comic_translation/comic_translation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/comic_translation_settings_screen.dart';
import 'package:zic/startup_platform.dart';
import 'package:zic/translation_composition.dart';

void main() {
  testWidgets('restoring OCR slider defaults preserves the existing cache identity', (tester) async {
    late Directory support;
    await tester.runAsync(() async {
      support = await Directory.systemTemp.createTemp('zic-translation-settings-ui-');
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(startupPlatformChannel, (call) async {
      if (call.method == 'applicationSupportPath') return support.path;
      return null;
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(ComicTranslationStore.instance.close);
      await tester.runAsync(() => support.delete(recursive: true));
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(startupPlatformChannel, null);
    });
    await tester.runAsync(initializeComicTranslation);
    ComicTranslationSettings.instance.values['indicatorOnlyWhileProcessing'] = false;
    await tester.runAsync(() => ComicTranslationSettings.instance.setComic('test', 'comic', {
      'showIndicator': false, 'indicatorOnlyWhileProcessing': false,
    }));
    await tester.pumpWidget(const MaterialApp(home: ComicTranslationSettingsScreen()));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.text('全局翻译设置'), findsOneWidget);
    expect(find.text('OCR 参数'), findsNothing);
    expect(find.text('保存'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('选择图片测试识别与翻译'), 250);
    expect(find.text('OCR 参数'), findsNothing, reason: 'tests do not require opening advanced settings');
    await tester.scrollUntilVisible(find.text('自动'), 250);
    await tester.tap(find.text('自动'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('高级设置'), -250);
    await tester.tap(find.text('高级设置'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('OCR 参数'), 250);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('OCR 参数'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OCR 参数'));
    await tester.pumpAndSettle();
    Slider threshold(double value) => tester.widget<Slider>(find.byWidgetPredicate(
      (widget) => widget is Slider && widget.min == .1 && widget.value == value));
    threshold(.45).onChanged!(.5);
    await tester.pump();
    // Flutter interpolates its discrete position back into the value range.
    // Its binary double may differ from the displayed two-decimal default.
    threshold(.5).onChanged!(.1 + (.9 - .1) * (7 / 16));
    await tester.pump();
    threshold(.35).onChanged!(.4);
    await tester.pump();
    threshold(.4).onChanged!(.1 + (.9 - .1) * (5 / 16));
    await tester.pump();
    final unclip = tester.widget<Slider>(find.byWidgetPredicate(
      (widget) => widget is Slider && widget.min == 1 && widget.max == 3));
    unclip.onChanged!(1 + (3 - 1) * (4 / 20));
    await tester.pump();
    await tester.runAsync(() => tester.tap(find.byTooltip('保存翻译设置')));
    await tester.runAsync(ComicTranslationSettings.instance.flush);
    await tester.pump();
    // Saving uses real file I/O; the visible progress animation cannot settle
    // until those futures complete outside the test's fake clock.
    final saveButton = find.widgetWithText(TextButton, '保存');
    for (var i = 0; i < 100 && tester.widget<TextButton>(saveButton).onPressed == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(tester.widget<TextButton>(saveButton).onPressed, isNotNull);
    await tester.pumpAndSettle();
    final saved = ComicTranslationSettings.instance.values;
    final parameters = ComicOcrParameters.fromSettings(saved);
    expect(parameters.detectionThreshold, .45);
    expect(parameters.recognitionThreshold, .35);
    expect(parameters.unclipRatio, 1.4);
    expect(parameters.cacheSuffix, isEmpty,
      reason: 'returning to the displayed defaults must reuse already translated pages');
    expect(saved['translationQuality'], 'custom');
    expect(saved['showIndicator'], isTrue);
    expect(saved['indicatorOnlyWhileProcessing'], isTrue);
    final inherited = ComicTranslationSettings.instance.forComic('test', 'other');
    expect(inherited['indicatorOnlyWhileProcessing'], isTrue);
    final overridden = ComicTranslationSettings.instance.forComic('test', 'comic');
    expect(overridden['showIndicator'], isFalse);
    expect(overridden['indicatorOnlyWhileProcessing'], isFalse);
  });
}

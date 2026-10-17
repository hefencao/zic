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
    await tester.pumpWidget(const MaterialApp(home: ComicTranslationSettingsScreen(
      sourceId: 'slider-defaults', comicId: 'comic',
    )));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('OCR 参数'), 250);
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
    await tester.pumpAndSettle();
    final saved = ComicTranslationSettings.instance.forComic('slider-defaults', 'comic');
    final parameters = ComicOcrParameters.fromSettings(saved);
    expect(parameters.detectionThreshold, .45);
    expect(parameters.recognitionThreshold, .35);
    expect(parameters.unclipRatio, 1.4);
    expect(parameters.cacheSuffix, isEmpty,
      reason: 'returning to the displayed defaults must reuse already translated pages');
    expect(saved['translationQuality'], 'custom');
  });
}

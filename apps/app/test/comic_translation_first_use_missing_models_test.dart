import 'dart:io';

import 'package:comic_translation/comic_translation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/comic_translation_settings_entry.dart';
import 'package:zic/comic_translation_setup_screen.dart';
import 'package:zic/startup_platform.dart';
import 'package:zic/translation_runtime.dart';

void main() {
  testWidgets('first use cannot finish without OCR or enable translation after cancellation', (tester) async {
    late Directory support;
    await tester.runAsync(() async {
      support = await Directory.systemTemp.createTemp('zic-translation-first-use-');
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(startupPlatformChannel, (call) async =>
      call.method == 'applicationSupportPath' ? support.path : null);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(ComicTranslationStore.instance.close);
      await tester.runAsync(() => support.delete(recursive: true));
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(startupPlatformChannel, null);
    });
    await tester.runAsync(initializeComicTranslation);
    var enabled = false;
    await tester.pumpWidget(MaterialApp(home: Builder(
      builder: (context) => Scaffold(body: TextButton(onPressed: () async {
        if (await ensureComicTranslationSetup(context)) enabled = true;
      }, child: const Text('enable'))),
    )));
    await tester.runAsync(() => tester.tap(find.text('enable')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.byKey(comicTranslationSetupKey), findsOneWidget);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('下载文字识别模型'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '下一步')).onPressed, isNull);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(enabled, isFalse);
    expect(ComicTranslationSettings.instance.values['comicTranslationSetupCompleted'], isFalse);
    expect(ComicTranslationSettings.instance.values['comicTranslationBackend'], 'none');
  });
}

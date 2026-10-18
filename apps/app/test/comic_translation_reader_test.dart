import 'dart:io';

import 'package:comic_translation/comic_translation.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/app_preferences.dart';
import 'package:zic/reader_runtime.dart';
import 'package:zic/startup_platform.dart';
import 'package:zic/translation_composition.dart';
import 'package:zic/webp_demo.dart' show defaultLocalMediaPipelineFactory;

void main() {
  testWidgets('a retained current page binds late translation initialization and settings', (tester) async {
    final appPreferences = AppPreferencesController();
    addTearDown(appPreferences.dispose);
    late Directory support;
    await tester.runAsync(() async { support = await Directory.systemTemp.createTemp('zic-translation-reader-'); });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(startupPlatformChannel, (call) async {
      if (call.method == 'applicationSupportPath') return support.path;
      return null;
    });
    await tester.runAsync(initializeComicTranslation);
    final chapter = ChapterManifest(
      sourceId: 'translation-test', comicId: 'comic',
      chapter: const Chapter(chapterId: 'chapter', comicId: 'comic', title: '静态页',
        sequence: 1, pageCount: 1, sourceRevision: '1'),
      pages: [PageAsset(pageId: 'page', chapterId: 'chapter', index: 0,
        uri: Uri.parse('assets/demo/pages/001.png'), contentKindHint: ContentKindHint.png)],
      readingDirection: ReadingDirection.ltr,
    );
    late ComicTranslationReaderExtension extension;
    var cleaned = false;
    Future<void> cleanup() async {
      if (cleaned) return;
      cleaned = true;
      late Future<void> closing;
      await tester.runAsync(() async { closing = extension.close(); });
      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 300; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.runAsync(() => closing);
      await tester.runAsync(ComicTranslationStore.instance.close);
      await tester.runAsync(() => support.delete(recursive: true));
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(startupPlatformChannel, null);
    }
    addTearDown(cleanup);
    await tester.pumpWidget(MaterialApp(home: PipelineReaderSessionHost(
      chapter: chapter, factory: defaultLocalMediaPipelineFactory,
      builder: (_, pipeline) => ReaderPresentationExtensionHost(
        pipeline: pipeline, factory: (_) => extension = ComicTranslationReaderExtension(
          pipeline, appPreferences: appPreferences),
        builder: (sidecar) => ReaderRuntimeScreen(chapter: chapter, pipeline: pipeline,
          presentationExtension: sidecar,
          artifactPageBuilder: (_, asset, reportFirstFrame, runtime) => const _Media(),
        ),
      ),
    )));
    final media = tester.state(find.byType(_Media));
    ComicTranslationSession? session() => tester.widget<ComicTranslationOverlay>(
      find.byType(ComicTranslationOverlay)).session;
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(session(), isNotNull, reason: 'initialization must reach the mounted page without navigation');
    final initial = session();
    await tester.runAsync(() => ComicTranslationSettings.instance.setComic('translation-test', 'comic', {'enabled': true}));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(session()!.enabled, isTrue);
    expect(tester.state(find.byType(_Media)), same(media));
    expect(session(), same(initial), reason: 'the enabled preference does not replace the translation session');
    ComicTranslationSettings.instance.values.addAll({
      'translationPrefetchPages': 0, 'translationCachePrefetchPages': 8, 'translationQuality': 'custom',
    });
    await tester.runAsync(ComicTranslationSettings.instance.save);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(session(), same(initial), reason: 'lookahead and preset labels do not invalidate translation results');
    expect(session()!.policy.prefetchPages, 0);
    expect(session()!.policy.cachePrefetchPages, 8);
    await tester.tap(find.byType(_Media));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.longPress(find.byKey(const ValueKey('reader-translation')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget,
      reason: 'the icon tooltip must not consume the settings long press');
    expect(session()!.enabled, isTrue);
    Future<void> indicatorMode(String label) async {
      await tester.runAsync(() => tester.tap(find.descendant(
        of: find.byKey(const ValueKey('reader-translation-indicator-mode')), matching: find.text(label))));
      await tester.runAsync(ComicTranslationSettings.instance.flush);
      await tester.pumpAndSettle();
    }
    await indicatorMode('处理中');
    expect(find.byKey(const ValueKey('reader-translation-status')), findsNothing,
      reason: 'the unavailable terminal state must not remain in processing-only mode');
    expect(session(), same(initial), reason: 'indicator mode must not restart OCR or translation');
    expect(ComicTranslationSettings.instance.forComic('translation-test', 'comic')['indicatorOnlyWhileProcessing'], isTrue);
    await indicatorMode('常驻');
    expect(find.byKey(const ValueKey('reader-translation-status')), findsOneWidget);
    expect(session(), same(initial));
    final pageNumber = find.descendant(of: find.byKey(const ValueKey('reader-translation-status')),
      matching: find.text('1'));
    expect(pageNumber, findsOneWidget);
    appPreferences.setDebugModeEnabled(false);
    await tester.pumpAndSettle();
    expect(pageNumber, findsNothing);
    expect(session(), same(initial), reason: 'app Debug display changes must not replace the session');
    appPreferences.setDebugModeEnabled(true);
    await tester.pumpAndSettle();
    expect(pageNumber, findsOneWidget);
    await indicatorMode('关闭');
    expect(find.byKey(const ValueKey('reader-translation-status')), findsNothing);
    expect(session(), same(initial), reason: 'indicator visibility must not restart OCR or translation');
    expect(tester.state(find.byType(_Media)), same(media));
    expect(session()!.enabled, isTrue);
    await indicatorMode('常驻');
    expect(find.byKey(const ValueKey('reader-translation-status')), findsOneWidget);
    expect(session(), same(initial));
    expect(find.byKey(const ValueKey('reader-translation-content')), findsOneWidget);
    await tester.runAsync(() => tester.tap(find.descendant(
      of: find.byKey(const ValueKey('reader-translation-content')), matching: find.text('翻译拟声词'))));
    await tester.runAsync(ComicTranslationSettings.instance.flush);
    await tester.pumpAndSettle();
    expect(ComicTranslationSettings.instance.forComic('translation-test', 'comic')['translateSoundEffects'], isTrue);
    expect(ComicTranslationSettings.instance.values['translateSoundEffects'], isFalse);
    expect(tester.state(find.byType(_Media)), same(media));
    await tester.longPress(find.byKey(const ValueKey('reader-translation')));
    await tester.pumpAndSettle();
    expect(find.text('应用到本漫画'), findsNothing, reason: 'OCR fine tuning starts collapsed');
    await tester.runAsync(() => tester.tap(find.descendant(
      of: find.byKey(const ValueKey('reader-translation-ocr')), matching: find.text('精细'))));
    await tester.runAsync(ComicTranslationSettings.instance.flush);
    await tester.pumpAndSettle();
    expect(session()!.policy.ocrParameters.maxAnalysisSide, 2240);
    expect(ComicTranslationSettings.instance.values['ocrMaxAnalysisSide'], 1600);
    expect(session()!.policy.contextPages, 2);
    expect(session()!.policy.prefetchPages, 0);
    expect(session()!.policy.cachePrefetchPages, 8);
    expect(tester.state(find.byType(_Media)), same(media));
    await tester.longPress(find.byKey(const ValueKey('reader-translation')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OCR 高级设置'));
    await tester.pumpAndSettle();
    final beforeOcrDraft = session();
    tester.widget<Slider>(find.byWidgetPredicate((widget) => widget is Slider && widget.min == 320))
        .onChanged!(1600);
    await tester.pump();
    tester.widget<Slider>(find.byWidgetPredicate((widget) => widget is Slider && widget.min == .1 && widget.value == .45))
        .onChanged!(.1 + (.9 - .1) * (7 / 16));
    await tester.pump();
    tester.widget<Slider>(find.byWidgetPredicate((widget) => widget is Slider && widget.min == .1 && widget.value == .35))
        .onChanged!(.1 + (.9 - .1) * (5 / 16));
    await tester.pump();
    tester.widget<Slider>(find.byWidgetPredicate((widget) => widget is Slider && widget.min == 1))
        .onChanged!(1 + (3 - 1) * (4 / 20));
    await tester.pump();
    expect(session(), same(beforeOcrDraft), reason: 'fine tuning is a draft until applied once');
    expect(session()!.policy.ocrParameters.maxAnalysisSide, 2240);
    await tester.ensureVisible(find.text('应用到本漫画'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.text('应用到本漫画')));
    await tester.runAsync(ComicTranslationSettings.instance.flush);
    await tester.pumpAndSettle();
    expect(session()!.policy.ocrParameters.cacheSuffix, isEmpty,
      reason: 'the comic sliders must preserve the default cache identity');
    expect(ComicTranslationSettings.instance.hasComicOcrOverride('translation-test', 'comic'), isTrue);
    await tester.longPress(find.byKey(const ValueKey('reader-translation')));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.descendant(
      of: find.byKey(const ValueKey('reader-translation-ocr')), matching: find.text('跟随全局'))));
    await tester.runAsync(ComicTranslationSettings.instance.flush);
    await tester.pumpAndSettle();
    expect(session()!.policy.ocrParameters.cacheSuffix, isEmpty);
    expect(ComicTranslationSettings.instance.hasComicOcrOverride('translation-test', 'comic'), isFalse);
    await tester.longPress(find.byKey(const ValueKey('reader-translation')));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.byTooltip('全局翻译设置')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.text('全局翻译设置'), findsOneWidget);
    expect(find.text('本漫画翻译设置'), findsNothing);
    expect(find.text('高级设置'), findsOneWidget);
    expect(find.text('OCR 参数'), findsNothing);
    Navigator.of(tester.element(find.text('全局翻译设置'))).pop();
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(const ValueKey('reader-translation')));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.descendant(
      of: find.byKey(const ValueKey('reader-translation-source-language')), matching: find.text('韩语'))));
    await tester.runAsync(ComicTranslationSettings.instance.flush);
    await tester.pumpAndSettle();
    expect(session()!.sourceLanguage, 'ko');
    expect(ComicTranslationSettings.instance.values['sourceLanguage'], 'auto');
    expect(tester.state(find.byType(_Media)), same(media));
    await tester.longPress(find.byKey(const ValueKey('reader-translation')));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.descendant(
      of: find.byKey(const ValueKey('reader-translation-source-language')), matching: find.text('自动'))));
    await tester.runAsync(ComicTranslationSettings.instance.flush);
    await tester.pumpAndSettle();
    expect(session()!.sourceLanguage, 'auto');
    ComicTranslationSettings.instance.values['targetLanguage'] = 'en';
    await tester.runAsync(ComicTranslationSettings.instance.save);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(session()!.targetLanguage, 'en');
    expect(tester.state(find.byType(_Media)), same(media));
    ComicTranslationSettings.instance.values['comicTranslationBackend'] = 'openaiCompatible';
    await tester.runAsync(ComicTranslationSettings.instance.save);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    final beforeKeyChange = session();
    await tester.runAsync(() => ComicTranslationSecrets.instance.setApiKey('default', 'reader-test-key'));
    await tester.runAsync(ComicTranslationSettings.instance.save);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(session(), isNot(same(beforeKeyChange)),
      reason: 'credential-only changes must replace the captured engine configuration');
    final beforeMetadataChange = session();
    final activeEngine = ComicTranslationEngineRegistry.instance.translationEngine;
    await tester.runAsync(() => ComicTranslationSettings.instance.setComic('translation-test', 'comic',
      const ComicOcrParameters(maxAnalysisSide: 2240).toSettings()));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(ComicTranslationEngineRegistry.instance.translationEngine, same(activeEngine),
      reason: 'comic OCR precision must reuse the configured translation engine');
    expect(session(), isNot(same(beforeMetadataChange)));
    final beforeProfileRename = session();
    final values = ComicTranslationSettings.instance.values;
    values['comicTranslationRemoteProfiles'] = [
      ComicTranslationRemoteProfile(id: 'default', name: 'Renamed profile',
        endpoint: values['comicTranslationRemoteEndpoint'] as String,
        model: values['comicTranslationRemoteModel'] as String,
        additionalPrompt: values['comicTranslationAdditionalPrompt'] as String).toJson(),
      const ComicTranslationRemoteProfile(id: 'unused', name: 'Other profile',
        endpoint: 'https://unused.invalid', model: 'other', additionalPrompt: '').toJson(),
    ];
    values['comicTranslationLocalModel'] = 'inactive-local-model';
    await tester.runAsync(ComicTranslationSettings.instance.save);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(ComicTranslationEngineRegistry.instance.translationEngine, same(activeEngine));
    expect(session(), same(beforeProfileRename),
      reason: 'profile labels and inactive model settings must preserve the active session and its output');
    final valid = session();
    ComicTranslationSettings.instance.values['comicTranslationBackend'] = 'deepl';
    await tester.runAsync(ComicTranslationSettings.instance.save);
    await tester.pump();
    expect(find.bySemanticsLabel(RegExp('翻译初始化失败')), findsOneWidget);
    ComicTranslationSettings.instance.values['comicTranslationBackend'] = 'openaiCompatible';
    await tester.runAsync(ComicTranslationSettings.instance.save);
    await tester.pump();
    expect(session(), same(valid));
    expect(session()!.enabled, isTrue);
    expect(find.bySemanticsLabel(RegExp('翻译初始化失败')), findsNothing);
    expect(tester.state(find.byType(_Media)), same(media));
    await cleanup();
  });
}

class _Media extends StatefulWidget {
  const _Media();
  @override
  State<_Media> createState() => _MediaState();
}

class _MediaState extends State<_Media> {
  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.white);
}

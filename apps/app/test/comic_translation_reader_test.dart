import 'dart:io';

import 'package:comic_translation/comic_translation.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/reader_runtime.dart';
import 'package:zic/startup_platform.dart';
import 'package:zic/translation_composition.dart';
import 'package:zic/webp_demo.dart' show defaultLocalMediaPipelineFactory;

void main() {
  testWidgets('a retained current page binds late translation initialization and settings', (tester) async {
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
        pipeline: pipeline, factory: (_) => extension = ComicTranslationReaderExtension(pipeline),
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
    await tester.tap(find.byType(_Media));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.longPress(find.byKey(const ValueKey('reader-translation')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget,
      reason: 'the icon tooltip must not consume the settings long press');
    expect(session()!.enabled, isTrue);
    Navigator.of(tester.element(find.text('翻译本漫画'))).pop();
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(const ValueKey('reader-translation')));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.widgetWithText(ChoiceChip, '韩语')));
    await tester.runAsync(ComicTranslationSettings.instance.flush);
    await tester.pumpAndSettle();
    expect(session()!.sourceLanguage, 'ko');
    expect(ComicTranslationSettings.instance.values['sourceLanguage'], 'auto');
    expect(tester.state(find.byType(_Media)), same(media));
    await tester.longPress(find.byKey(const ValueKey('reader-translation')));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.widgetWithText(ChoiceChip, '自动')));
    await tester.runAsync(ComicTranslationSettings.instance.flush);
    await tester.pumpAndSettle();
    expect(session()!.sourceLanguage, 'auto');
    await tester.runAsync(() => ComicTranslationSettings.instance.setComic('translation-test', 'comic', {'targetLanguage': 'en'}));
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
    final valid = session();
    ComicTranslationSettings.instance.values['comicTranslationBackend'] = 'deepl';
    await tester.runAsync(ComicTranslationSettings.instance.save);
    await tester.pump();
    expect(find.textContaining('翻译初始化失败'), findsOneWidget);
    ComicTranslationSettings.instance.values['comicTranslationBackend'] = 'openaiCompatible';
    await tester.runAsync(ComicTranslationSettings.instance.save);
    await tester.pump();
    expect(session(), same(valid));
    expect(session()!.enabled, isTrue);
    expect(find.textContaining('翻译初始化失败'), findsNothing);
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

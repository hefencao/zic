import 'dart:ui' as ui;

import 'package:comic_translation/comic_translation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(ComicTranslationOverlayController.clearRetainedLayouts);

  testWidgets('invisible translations never clear their source image', (tester) async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.white, BlendMode.src);
    final picture = recorder.endRecording();
    final image = await tester.runAsync(() => picture.toImage(1, 1));
    final data = await tester.runAsync(() => image!.toByteData(format: ui.ImageByteFormat.png));
    image!.dispose();
    picture.dispose();
    const identity = ComicTranslationPageIdentity(
      imageKey: 'padding', sourceKey: 'test', comicId: 'comic', chapterId: 'chapter',
      pageIndex: 0, mediaKind: ComicTranslationMediaKind.staticImage,
    );
    final session = ComicTranslationSession(enabled: true, sourceLanguage: 'ja', targetLanguage: 'en');
    final page = session.listenable(identity) as ValueNotifier<ComicTranslationPageState>;
    page.value = ComicTranslationPageState(ComicTranslationPhase.ready,
      cleanOverlayPng: data!.buffer.asUint8List(),
      artifact: ComicTranslationArtifact(
        contentDigest: '0123456789abcdef', ocrDigest: 'ocr', engineId: 'test', modelVersion: '1',
        sourceLanguage: 'ja', targetLanguage: 'en', contextDigest: '', imageWidth: 300, imageHeight: 400,
        mediaKind: ComicTranslationMediaKind.staticImage, animatedMode: AnimatedTranslationMode.posterFrame,
        regions: [for (var i = 0; i < 3; i++) ComicTranslatedRegion(
          ocrRegionId: 'r$i', sourceText: '文字',
          translatedText: i == 1 ? 'Hello' : comicTranslationBreakMarker,
          polygon: [NormalizedPoint(0.2, 0.1 + i * 0.25), NormalizedPoint(0.8, 0.1 + i * 0.25),
            NormalizedPoint(0.8, 0.2 + i * 0.25), NormalizedPoint(0.2, 0.2 + i * 0.25)],
          orientation: ComicTextOrientation.horizontal, kind: ComicTextKind.dialogue, readingOrder: i,
          sourceMaskPolygons: [], bubbleGroupId: i == 0 ? 0 : 1)],
      ),
    );
    final controller = ComicTranslationOverlayController();
    const mediaKey = ValueKey('padding-media');
    await tester.pumpWidget(MaterialApp(home: Center(child: SizedBox(width: 300, height: 400,
      child: ComicTranslationOverlay(session: session, identity: identity, controller: controller,
        child: const ColoredBox(key: mediaKey, color: Colors.red)),
    ))));
    final bounds = tester.getRect(find.byKey(mediaKey));
    final translatedPoint = bounds.topLeft + Offset(bounds.width * 0.5, bounds.height * 0.4);
    var prepared = false;
    for (var i = 0; i < 300 && !prepared; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 16));
      prepared = controller.peekSourceAt(translatedPoint);
    }
    expect(prepared, isTrue, reason: 'visible translations must still finish');
    await tester.pump(const Duration(milliseconds: 1600));
    final clip = tester.widget<ClipPath>(find.descendant(
      of: find.byType(ComicTranslationOverlay), matching: find.byType(ClipPath)));
    final path = clip.clipper!.getClip(const Size(300, 400));
    expect(path.contains(const Offset(150, 160)), isTrue);
    expect(path.contains(const Offset(150, 60)), isFalse,
      reason: 'an entirely invisible unit must preserve its original image');
    expect(path.contains(const Offset(150, 260)), isFalse,
      reason: 'a padded line beside valid text must also preserve its original image');
    await tester.pumpWidget(const SizedBox.shrink());
    await session.close();
  });

  testWidgets('translations and resolved taps remain available during another animation', (tester) async {
    const identity = ComicTranslationPageIdentity(
      imageKey: 'image', sourceKey: 'test', comicId: 'comic', chapterId: 'chapter',
      pageIndex: 0, mediaKind: ComicTranslationMediaKind.staticImage,
    );
    final session = ComicTranslationSession(enabled: true, sourceLanguage: 'ja', targetLanguage: 'en');
    final page = session.listenable(identity) as ValueNotifier<ComicTranslationPageState>;
    page.value = const ComicTranslationPageState(ComicTranslationPhase.ready,
      artifact: ComicTranslationArtifact(
        contentDigest: '0123456789abcdef', ocrDigest: 'ocr', engineId: 'test', modelVersion: '1',
        sourceLanguage: 'ja', targetLanguage: 'en', contextDigest: '', imageWidth: 300, imageHeight: 400,
        mediaKind: ComicTranslationMediaKind.staticImage, animatedMode: AnimatedTranslationMode.posterFrame,
        regions: [ComicTranslatedRegion(ocrRegionId: 'r0', sourceText: 'こんにちは', translatedText: 'Hello',
          polygon: [NormalizedPoint(0.2, 0.3), NormalizedPoint(0.8, 0.3),
            NormalizedPoint(0.8, 0.5), NormalizedPoint(0.2, 0.5)],
          orientation: ComicTextOrientation.horizontal, kind: ComicTextKind.dialogue, readingOrder: 0,
          sourceMaskPolygons: [], bubbleGroupId: 0,
          bubblePolygon: [NormalizedPoint(0.1, 0.2), NormalizedPoint(0.9, 0.2),
            NormalizedPoint(0.9, 0.6), NormalizedPoint(0.1, 0.6)])],
      ),
    );
    final controller = ComicTranslationOverlayController();
    final diagnostics = <Map<String, Object?>>[];
    const mediaKey = ValueKey('peek-media');
    late Offset point;
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: Center(child: SizedBox(width: 300, height: 400,
        child: ComicTranslationOverlay(session: session, identity: identity, controller: controller,
          onDiagnostic: diagnostics.add,
          child: const Stack(fit: StackFit.expand, children: [
            ColoredBox(key: mediaKey, color: Colors.white),
            Align(alignment: Alignment.topCenter, child: SizedBox.square(
              dimension: 20, child: CircularProgressIndicator())),
          ])),
      ))));
      final bounds = tester.getRect(find.byKey(mediaKey));
      point = bounds.topLeft + Offset(bounds.width * 0.5, bounds.height * 0.4);
      var consumed = false;
      for (var i = 0; i < 100 && !consumed; i++) {
        await Future<void>.delayed(Duration.zero);
        await tester.pump(const Duration(milliseconds: 16));
        consumed = controller.peekSourceAt(point);
      }
      expect(consumed, isTrue, reason: 'a painted translated bubble must accept its resolved tap');
    });
    expect(controller.peekSourceAt(point), isTrue);
    await tester.pump(const Duration(milliseconds: 600));
    expect(controller.peekSourceAt(point), isFalse, reason: 'the translated block is hidden during peek');
    await tester.pump(const Duration(seconds: 1));
    expect(controller.peekSourceAt(point), isTrue, reason: 'the block is available again after 1.5 seconds');
    await tester.pump(const Duration(milliseconds: 1600));
    (session.fontScaleListenable as ValueNotifier<double>).value = 1.03;
    await tester.pump();
    expect(controller.peekSourceAt(point), isTrue,
      reason: 'a font-metric update must keep the painted translation until its replacement is ready');
    expect(diagnostics.where((event) => event['stage'] == 'overlay-first-frame'), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await session.close();
  });

  testWidgets('initialization, disable and backend replacement retain the media child', (tester) async {
    const identity = ComicTranslationPageIdentity(
      imageKey: 'image', sourceKey: 'test', comicId: 'comic', chapterId: 'chapter',
      pageIndex: 0, mediaKind: ComicTranslationMediaKind.staticImage,
    );
    final first = ComicTranslationSession(enabled: true, sourceLanguage: 'ja', targetLanguage: 'zh-CN');
    final second = ComicTranslationSession(enabled: true, sourceLanguage: 'ja', targetLanguage: 'en');
    Future<void> paint(ComicTranslationSession? session) => tester.pumpWidget(
      MaterialApp(home: SizedBox(width: 200, height: 300, child: ComicTranslationOverlay(
        session: session, identity: identity, child: const _MediaChild(),
      ))),
    );
    await paint(null);
    final media = tester.state(find.byType(_MediaChild));
    for (final session in [first, null, second, first]) {
      await paint(session);
      expect(tester.state(find.byType(_MediaChild)), same(media));
    }
    first.setEnabled(false);
    await paint(first);
    expect(tester.state(find.byType(_MediaChild)), same(media));
    await tester.pumpWidget(const SizedBox.shrink());
    await first.close();
    await second.close();
  });

  for (final changeTheme in [false, true]) {
  testWidgets('a partially painted page survives ${changeTheme ? 'theme' : 'font'} updates', (tester) async {
    const identity = ComicTranslationPageIdentity(
      imageKey: 'partial', sourceKey: 'test', comicId: 'comic', chapterId: 'chapter',
      pageIndex: 0, mediaKind: ComicTranslationMediaKind.staticImage,
    );
    final session = ComicTranslationSession(enabled: true, sourceLanguage: 'ja', targetLanguage: 'en');
    final page = session.listenable(identity) as ValueNotifier<ComicTranslationPageState>;
    page.value = ComicTranslationPageState(ComicTranslationPhase.ready,
      artifact: ComicTranslationArtifact(
        contentDigest: '0123456789abcdef', ocrDigest: 'ocr', engineId: 'test', modelVersion: '1',
        sourceLanguage: 'ja', targetLanguage: 'en', contextDigest: '', imageWidth: 300, imageHeight: 400,
        mediaKind: ComicTranslationMediaKind.staticImage, animatedMode: AnimatedTranslationMode.posterFrame,
        regions: [for (var i = 0; i < 2; i++) ComicTranslatedRegion(
          ocrRegionId: 'r$i', sourceText: 'こんにちは', translatedText: 'Hello',
          polygon: [NormalizedPoint(0.2, 0.2 + i * 0.4), NormalizedPoint(0.8, 0.2 + i * 0.4),
            NormalizedPoint(0.8, 0.3 + i * 0.4), NormalizedPoint(0.2, 0.3 + i * 0.4)],
          orientation: ComicTextOrientation.horizontal, kind: ComicTextKind.dialogue, readingOrder: i,
          sourceMaskPolygons: [], bubbleGroupId: i,
          bubblePolygon: [NormalizedPoint(0.1, 0.1 + i * 0.4), NormalizedPoint(0.9, 0.1 + i * 0.4),
            NormalizedPoint(0.9, 0.4 + i * 0.4), NormalizedPoint(0.1, 0.4 + i * 0.4)])],
      ),
    );
    final controller = ComicTranslationOverlayController();
    final diagnostics = <Map<String, Object?>>[];
    const mediaKey = ValueKey('partial-media');
    Future<void> paint({bool dark = false}) => tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
      themeAnimationDuration: Duration.zero,
      home: Center(child: SizedBox(width: 300, height: 400,
        child: ComicTranslationOverlay(session: session, identity: identity, controller: controller,
          onDiagnostic: diagnostics.add,
          child: const ColoredBox(key: mediaKey, color: Colors.white)),
      )),
    ));
    await tester.runAsync(() => paint());
    final bounds = tester.getRect(find.byKey(mediaKey));
    final first = bounds.topLeft + Offset(bounds.width * 0.5, bounds.height * 0.25);
    final second = bounds.topLeft + Offset(bounds.width * 0.5, bounds.height * 0.65);
    var visible = false;
    for (var i = 0; i < 300 && !visible; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 16));
      visible = controller.peekSourceAt(first);
    }
    expect(visible, isTrue);
    expect(controller.peekSourceAt(second), isFalse,
      reason: 'the first balloon is visible while the rest of the page still prepares');
    await tester.pump(const Duration(milliseconds: 1600));
    if (changeTheme) {
      await paint(dark: true);
    } else {
      (session.fontScaleListenable as ValueNotifier<double>).value = 1.03;
      await tester.pump();
    }
    expect(controller.peekSourceAt(first), isTrue,
      reason: 'an already painted balloon must remain until the replacement layout is ready');
    expect(diagnostics.lastWhere((event) => event['stage'] == 'layout-started')['retained'], isTrue);
    if (!changeTheme) {
      (session.fontScaleListenable as ValueNotifier<double>).value = 1;
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 1600));
    var secondVisible = false;
    for (var i = 0; i < 3000 && !secondVisible; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 16));
      secondVisible = controller.peekSourceAt(second);
    }
    expect(secondVisible, isTrue, reason: 'the replacement must eventually finish every balloon');
    await tester.pump(const Duration(milliseconds: 1600));
    (session.fontScaleListenable as ValueNotifier<double>).value = 1.04;
    await tester.pump();
    expect(controller.peekSourceAt(first), isTrue);
    await tester.pump();
    expect(controller.peekSourceAt(second), isTrue,
      reason: 'peeking one balloon during a reflow must leave other painted balloons visible');
    expect(diagnostics.where((event) => event['stage'] == 'source-peek' && event['active'] == false), isNotEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1600));
    await session.close();
  });
  }
}

class _MediaChild extends StatefulWidget {
  const _MediaChild();
  @override
  State<_MediaChild> createState() => _MediaChildState();
}

class _MediaChildState extends State<_MediaChild> {
  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.white);
}

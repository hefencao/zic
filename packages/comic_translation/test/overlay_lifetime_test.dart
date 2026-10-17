import 'package:comic_translation/comic_translation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('resolved taps find a translated bubble and restore it after peeking', (tester) async {
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
    const mediaKey = ValueKey('peek-media');
    await tester.pumpWidget(MaterialApp(home: Center(child: SizedBox(width: 300, height: 400,
      child: ComicTranslationOverlay(session: session, identity: identity, controller: controller,
        child: const ColoredBox(key: mediaKey, color: Colors.white)),
    ))));
    final bounds = tester.getRect(find.byKey(mediaKey));
    final point = bounds.topLeft + Offset(bounds.width * 0.5, bounds.height * 0.4);
    var consumed = false;
    for (var i = 0; i < 100 && !consumed; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 16));
      consumed = controller.peekSourceAt(point);
    }
    expect(consumed, isTrue, reason: 'a painted translated bubble must accept its resolved tap');
    await tester.pump(const Duration(milliseconds: 600));
    expect(controller.peekSourceAt(point), isFalse, reason: 'the translated block is hidden during peek');
    await tester.pump(const Duration(seconds: 1));
    expect(controller.peekSourceAt(point), isTrue, reason: 'the block is available again after 1.5 seconds');
    await tester.pump(const Duration(milliseconds: 1600));
    (session.bodyFontRatioListenable as ValueNotifier<double?>).value = 0.03;
    await tester.pump();
    expect(controller.peekSourceAt(point), isTrue,
      reason: 'a font-metric update must keep the painted translation until its replacement is ready');
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

import 'dart:convert';
import 'dart:io';

import 'package:comic_translation/comic_translation.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('later cached pages cannot reflow a visible page or change its groups', (tester) async {
    await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('zic-layout-stability-');
      await ComicTranslationStore.instance.init(temp.path);
      final first = await _cachePage(temp, 0, large: false);
      final later = await _cachePage(temp, 1, large: true);
      final session = ComicTranslationSession(enabled: true, sourceLanguage: 'ja', targetLanguage: 'en',
        engines: ComicTranslationEngineRegistry()
          ..ocrEngine = _CachedOcr()..translationEngine = _CachedTranslator());
      final events = <Map<String, Object?>>[];
      try {
        session.reportPages(current: [first], interaction: ComicTranslationInteraction.idle);
        await _waitReady(session, first);
        await tester.pumpWidget(MaterialApp(home: Center(child: SizedBox(width: 300, height: 400,
          child: ComicTranslationOverlay(session: session, identity: first, onDiagnostic: events.add,
            child: const ColoredBox(color: Colors.white)),
        ))));
        await _finishLayout(tester, events, 1);
        final before = events.lastWhere((event) => event['stage'] == 'layout-ready')['blocks'];
        expect(before, hasLength(4), reason: 'connected contours must retain refined text groups');
        final starts = events.where((event) => event['stage'] == 'layout-started').length;

        session.reportPages(current: [first], near: [later], interaction: ComicTranslationInteraction.idle);
        await _waitReady(session, later);
        await tester.pump();
        expect(events.where((event) => event['stage'] == 'layout-started'), hasLength(starts),
          reason: 'another page completing must not replace the visible page typography');

        // A deliberate typography update may change glyphs, never group members
        // or source-derived available bounds.
        (session.fontScaleListenable as ValueNotifier<double>).value = 1.1;
        await tester.pump();
        await _finishLayout(tester, events, 2);
        final after = events.lastWhere((event) => event['stage'] == 'layout-ready')['blocks'];
        List<Object?> geometry(Object? value) => (value as List).map((block) {
          final map = block as Map;
          return [map['key'], map['regions'], map['bounds']];
        }).toList();
        expect(geometry(after), geometry(before));

        // Larger lettering elsewhere on the same page changes its preferred
        // body font, but cannot expand these four groups into adjacent lobes.
        final page = session.listenable(first) as ValueNotifier<ComicTranslationPageState>;
        final artifact = page.value.artifact!;
        final other = session.listenable(later).value.artifact!;
        page.value = ComicTranslationPageState(ComicTranslationPhase.ready,
          artifact: ComicTranslationArtifact.fromJson({
            ...artifact.toJson(), 'contentDigest': '${artifact.contentDigest}aa',
            'regions': [...artifact.regions, ...other.regions].map((region) => region.toJson()).toList(),
          }));
        await tester.pump();
        await _finishLayout(tester, events, 3);
        final combined = events.lastWhere((event) => event['stage'] == 'layout-ready')['blocks'] as List;
        final originalGroups = combined.where((block) =>
            ['layout:r0', 'layout:r1', 'layout:r2', 'layout:r3'].contains((block as Map)['key'])).toList();
        expect(geometry(originalGroups), geometry(before));
        final metrics = events.where((event) => event['stage'] == 'layout-started').toList();
        expect(metrics.last['bodyFontRatio'], isNot(metrics.first['bodyFontRatio']),
          reason: 'this fixture must exercise different body font preferences');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await session.close();
        await ComicTranslationStore.instance.close();
        await temp.delete(recursive: true);
      }
    });
  });
}

Future<void> _finishLayout(WidgetTester tester, List<Map<String, Object?>> events, int count) async {
  for (var i = 0; i < 5000; i++) {
    if (events.where((event) => event['stage'] == 'layout-ready').length >= count) return;
    await Future<void>.delayed(Duration.zero);
    await tester.pump(const Duration(milliseconds: 16));
  }
  fail('layout did not finish');
}

Future<void> _waitReady(ComicTranslationSession session, ComicTranslationPageIdentity page) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (session.listenable(page).value.phase != ComicTranslationPhase.ready) {
    final state = session.listenable(page).value;
    if (state.phase == ComicTranslationPhase.failed || DateTime.now().isAfter(deadline)) {
      fail('cached page did not become ready: ${state.phase}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Future<ComicTranslationPageIdentity> _cachePage(Directory temp, int index, {required bool large}) async {
  final bytes = List<int>.filled(64 + index, index + 1);
  final file = await File('${temp.path}/page$index.bin').writeAsBytes(bytes);
  final digest = sha256.convert(bytes).toString();
  final regions = <ComicOcrRegion>[];
  for (var i = 0; i < (large ? 8 : 4); i++) {
    final x = large ? 0.1 + i % 4 * 0.22 : 0.08 + i * 0.24;
    final y = large ? 0.04 + i ~/ 4 * 0.23 : 0.6;
    final width = large ? 0.1 : 0.025;
    final height = large ? 0.2 : 0.08;
    regions.add(ComicOcrRegion(id: 'r${large ? i + 100 : i}', text: 'こんにちは', confidence: 1,
      polygon: _rect(x, y, width, height), sourceMaskPolygons: [],
      orientation: ComicTextOrientation.vertical, kind: ComicTextKind.dialogue, readingOrder: i,
      bubbleGroupId: large ? i + 100 : 0,
      bubblePolygon: large ? _rect(x - .02, y - .02, width + .04, height + .04)
          : _rect(.03, .55, .94, .2)));
  }
  final ocr = ComicOcrArtifact(contentDigest: digest, engineId: 'cached-ocr', modelVersion: '1',
    sourceLanguage: 'ja', imageWidth: 300, imageHeight: 400,
    mediaKind: ComicTranslationMediaKind.staticImage, animatedMode: AnimatedTranslationMode.posterFrame,
    regions: regions);
  final ocrDigest = await ComicTranslationStore.instance.storeOcr(ocr);
  await ComicTranslationStore.instance.storeTranslation(ComicTranslationArtifact(
    contentDigest: digest, ocrDigest: ocrDigest, engineId: 'cached-mt',
    modelVersion: 'artifact-v3:1:sfx=false', sourceLanguage: 'ja', targetLanguage: 'en',
    contextDigest: sha256.convert(utf8.encode('[]')).toString(), imageWidth: 300, imageHeight: 400,
    mediaKind: ComicTranslationMediaKind.staticImage, animatedMode: AnimatedTranslationMode.posterFrame,
    regions: [for (final region in regions) ComicTranslatedRegion(ocrRegionId: region.id,
      sourceText: region.text, translatedText: 'Hello', polygon: region.polygon,
      orientation: region.orientation, kind: region.kind, readingOrder: region.readingOrder,
      sourceMaskPolygons: [], bubbleGroupId: region.bubbleGroupId, bubblePolygon: region.bubblePolygon)],
  ));
  return ComicTranslationPageIdentity(imageKey: file.uri.toString(), sourceKey: 'test',
    comicId: 'comic', chapterId: 'chapter', pageIndex: index,
    mediaKind: ComicTranslationMediaKind.staticImage);
}

List<NormalizedPoint> _rect(double x, double y, double width, double height) => [
  NormalizedPoint(x, y), NormalizedPoint(x + width, y),
  NormalizedPoint(x + width, y + height), NormalizedPoint(x, y + height),
];

// Cache hits must not call or load either engine; Fake throws on such calls.
class _CachedOcr extends Fake implements ComicOcrEngine {
  @override
  String get id => 'cached-ocr';
  @override
  String get modelVersion => '1';
}

class _CachedTranslator extends Fake implements ComicTextTranslationEngine {
  @override
  ComicTranslationContextMode get contextMode => ComicTranslationContextMode.none;
  @override
  ComicTranslationEngineIdentity identityFor(ComicTranslationRequest request) =>
      const ComicTranslationEngineIdentity(id: 'cached-mt', modelVersion: '1');
}

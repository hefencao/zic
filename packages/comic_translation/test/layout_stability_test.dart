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
        final areas = (before as List).map((block) => _layoutBounds(block as Map)).toList();
        for (var i = 0; i < areas.length; i++) {
          for (var j = i + 1; j < areas.length; j++) {
            expect(areas[i].overlaps(areas[j]), isFalse,
              reason: 'separate groups must not share the connected contour layout area');
          }
        }
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

  testWidgets('a separate OCR mark cannot move over body text in the same bubble', (tester) async {
    await tester.runAsync(() async {
      const identity = ComicTranslationPageIdentity(imageKey: 'page5', sourceKey: 'test',
        comicId: 'comic', chapterId: 'chapter', pageIndex: 4,
        mediaKind: ComicTranslationMediaKind.staticImage);
      final session = ComicTranslationSession(enabled: true, sourceLanguage: 'ja', targetLanguage: 'zh-CN');
      final page = session.listenable(identity) as ValueNotifier<ComicTranslationPageState>;
      final bubble = _rect(.18, .48, .14, .14);
      ComicTranslatedRegion region(String id, String source, String translated,
          double x, double y, double width, double height) => ComicTranslatedRegion(
        ocrRegionId: id, sourceText: source, translatedText: translated,
        polygon: _rect(x, y, width, height), sourceMaskPolygons: [],
        orientation: ComicTextOrientation.vertical, kind: ComicTextKind.dialogue,
        readingOrder: 0, bubbleGroupId: 4, bubblePolygon: bubble);
      page.value = ComicTranslationPageState(ComicTranslationPhase.ready,
        artifact: ComicTranslationArtifact(contentDigest: 'page5-0123456789', ocrDigest: 'ocr',
          engineId: 'cached', modelVersion: '1', sourceLanguage: 'ja', targetLanguage: 'zh-CN',
          contextDigest: '', imageWidth: 1000, imageHeight: 1404,
          mediaKind: ComicTranslationMediaKind.staticImage, animatedMode: AnimatedTranslationMode.posterFrame,
          regions: [
            region('body-1', 'あんたでしょ', '明明是你吧', .255, .502, .027, .087),
            region('body-2', 'やめなかったの', '不肯停下来的', .276, .502, .031, .098),
            region('mark', '北', '北', .209, .548, .041, .041),
          ]));
      final events = <Map<String, Object?>>[];
      final controller = ComicTranslationOverlayController();
      const mediaKey = ValueKey('shared-bubble-media');
      try {
        await tester.pumpWidget(MaterialApp(home: Align(alignment: Alignment.topLeft,
          child: SizedBox(width: 400, height: 561.6,
            child: ComicTranslationOverlay(session: session, identity: identity,
              onDiagnostic: events.add, controller: controller,
              child: const ColoredBox(key: mediaKey, color: Colors.white))))));
        await _finishLayout(tester, events, 1);
        final blocks = events.lastWhere((event) => event['stage'] == 'layout-ready')['blocks'] as List;
        expect(blocks, hasLength(2), reason: 'the mark remains separate from the dialogue');
        final body = blocks.singleWhere((block) => ((block as Map)['regions'] as List).length == 2) as Map;
        final mark = blocks.singleWhere((block) => ((block as Map)['regions'] as List).length == 1) as Map;
        expect(_layoutBounds(body).overlaps(_layoutBounds(mark)), isFalse);
        expect(_layoutBounds(body, field: 'textBounds').overlaps(
          _layoutBounds(mark, field: 'textBounds')), isFalse);
        final bubbleBounds = Rect.fromLTWH(.18 * 400, .48 * 561.6, .14 * 400, .14 * 561.6);
        for (final block in [body, mark]) {
          expect(_layoutBounds(block).intersect(bubbleBounds), _layoutBounds(block),
            reason: 'reserving a smaller cell must not trigger layout outside a valid contour');
        }
        expect(_layoutBounds(body).center.dx, greaterThan(_layoutBounds(mark).center.dx),
          reason: 'the source mark remains to the left of the body');
        expect(body['fontSize'], greaterThan(3));
        expect(mark['fontSize'], greaterThan(3));
        final origin = tester.getTopLeft(find.byKey(mediaKey));
        expect(controller.peekSourceAt(origin + _layoutBounds(mark).center), isTrue);
        await tester.pump();
        expect(controller.peekSourceAt(origin + _layoutBounds(mark).center), isFalse,
          reason: 'the dialogue hit area must not include the hidden mark');
        expect(controller.peekSourceAt(origin + _layoutBounds(body).center), isTrue,
          reason: 'peeking the mark cannot hide the dialogue sharing its native contour');

        final artifact = page.value.artifact!;
        page.value = ComicTranslationPageState(ComicTranslationPhase.ready,
          artifact: ComicTranslationArtifact.fromJson({...artifact.toJson(),
            'regions': artifact.regions.map((region) => {...region.toJson(),
              if (region.ocrRegionId == 'mark') 'translatedText': '',
            }).toList(),
          }));
        await tester.pump();
        await _finishLayout(tester, events, 2);
        final withoutMark = events.lastWhere((event) => event['stage'] == 'layout-ready')['blocks'] as List;
        expect(withoutMark, hasLength(1));
        expect(_layoutBounds(withoutMark.single as Map), _layoutBounds(body),
          reason: 'original text kept untranslated still reserves its source space');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await session.close();
      }
    });
  });
}

Rect _layoutBounds(Map block, {String field = 'bounds'}) {
  final bounds = block[field] as List;
  return Rect.fromLTRB((bounds[0] as num).toDouble(), (bounds[1] as num).toDouble(),
    (bounds[2] as num).toDouble(), (bounds[3] as num).toDouble());
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

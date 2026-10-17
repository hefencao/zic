import 'dart:async';
import 'dart:io';

import 'package:comic_translation/comic_translation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lease is released on rejected input and remains live until caller finishes', () async {
    final directory = await Directory.systemTemp.createTemp('zic-translation-input-');
    try {
      var releases = 0;
      const identity = ComicTranslationPageIdentity(imageKey: 'opaque', sourceKey: 'test',
        comicId: 'comic', chapterId: 'chapter', pageIndex: 0,
        mediaKind: ComicTranslationMediaKind.staticImage);
      final image = File('${directory.path}/page');
      final resolver = ComicTranslationInputResolver(openFile: (_) async =>
          ComicTranslationInputFile(path: image.path, release: () { releases++; }));
      expect(await resolver.resolve(identity), isNull);
      expect(releases, 1);
      await image.writeAsBytes(List.generate(256, (i) => i));
      final input = await resolver.resolve(identity);
      expect(input, isNotNull);
      expect(releases, 1);
      await input!.release();
      expect(releases, 2);
      final miss = await const ComicTranslationInputResolver().resolve(identity);
      expect(miss, isNull);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('session close waits for running OCR, releases its input then unloads', () async {
    final directory = await Directory.systemTemp.createTemp('zic-translation-close-');
    final store = ComicTranslationStore.instance;
    await store.init(directory.path);
    try {
      final file = File('${directory.path}/page');
      await file.writeAsBytes(List.generate(256, (i) => i));
      const identity = ComicTranslationPageIdentity(imageKey: 'opaque', sourceKey: 'test',
        comicId: 'comic', chapterId: 'chapter', pageIndex: 0,
        mediaKind: ComicTranslationMediaKind.staticImage);
      final events = <String>[];
      final ocr = _HeldOcr(events);
      final registry = ComicTranslationEngineRegistry()
        ..configure(ocrEngine: ocr, translationEngine: _Translator());
      final session = ComicTranslationSession(
        enabled: true, sourceLanguage: 'ja', targetLanguage: 'zh-CN', engines: registry,
        inputResolver: ComicTranslationInputResolver(openFile: (_) async =>
            ComicTranslationInputFile(path: file.path, release: () { events.add('release'); })),
      );
      session.reportPages(current: [identity], interaction: ComicTranslationInteraction.idle);
      await ocr.started.future.timeout(const Duration(seconds: 3));
      var closed = false;
      final closing = session.close().then((_) { closed = true; });
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(events, isEmpty);
      ocr.finish.complete();
      await closing;
      expect(events, ['release', 'unload']);
      expect(identical(session.close(), session.close()), isTrue);
    } finally {
      await store.close();
      await directory.delete(recursive: true);
    }
  });
  test('close waits for a parallel cache probe before releasing the engine lease', () async {
    final directory = await Directory.systemTemp.createTemp('zic-translation-probe-');
    final store = ComicTranslationStore.instance;
    await store.init(directory.path);
    final events = <String>[];
    final ocr = _HeldOcr(events);
    final probeStarted = Completer<void>();
    final finishProbe = Completer<void>();
    final runningReleased = Completer<void>();
    ComicTranslationSession? session;
    try {
      final file = File('${directory.path}/page');
      await file.writeAsBytes(List<int>.filled(387, 59));
      ComicTranslationPageIdentity page(int index) => ComicTranslationPageIdentity(
        imageKey: 'opaque-$index', sourceKey: 'probe', comicId: 'comic', chapterId: 'chapter',
        pageIndex: index, mediaKind: ComicTranslationMediaKind.staticImage);
      final current = page(0);
      final running = page(1);
      session = ComicTranslationSession(enabled: true, sourceLanguage: 'ja', targetLanguage: 'zh-CN',
        engines: ComicTranslationEngineRegistry()..configure(ocrEngine: ocr, translationEngine: _Translator()),
        inputResolver: ComicTranslationInputResolver(openFile: (identity) async {
          if (identity == current) {
            probeStarted.complete();
            await finishProbe.future;
          }
          return ComicTranslationInputFile(path: file.path, release: () {
            events.add('release-${identity.pageIndex}');
            if (identity == running) runningReleased.complete();
          });
        }));
      session.reportPages(current: [running], interaction: ComicTranslationInteraction.idle);
      await ocr.started.future.timeout(const Duration(seconds: 3));
      session.reportPages(current: [current], near: [running], interaction: ComicTranslationInteraction.idle);
      await probeStarted.future.timeout(const Duration(seconds: 3));
      var closed = false;
      final closing = session.close().then((_) { closed = true; });
      ocr.finish.complete();
      await runningReleased.future;
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(events, ['release-1']);
      finishProbe.complete();
      await closing.timeout(const Duration(seconds: 3));
      expect(events, ['release-1', 'release-0', 'unload']);
    } finally {
      if (!ocr.finish.isCompleted) ocr.finish.complete();
      if (!finishProbe.isCompleted) finishProbe.complete();
      await session?.close();
      await store.close();
      await directory.delete(recursive: true);
    }
  });
}

final class _HeldOcr implements ComicOcrEngine {
  _HeldOcr(this.events);
  final List<String> events;
  final started = Completer<void>();
  final finish = Completer<void>();
  @override
  String get id => 'held';
  @override
  String get modelVersion => '1';
  @override
  bool get supportsAnimatedPosterFrame => false;
  @override
  Future<void> load(String language) async {}
  @override
  Future<ComicOcrArtifact> recognize(ComicOcrInput input) async {
    started.complete();
    await finish.future;
    return ComicOcrArtifact(contentDigest: input.contentDigest, engineId: id,
      modelVersion: modelVersion, sourceLanguage: input.sourceLanguage,
      imageWidth: 1, imageHeight: 1, mediaKind: ComicTranslationMediaKind.staticImage,
      animatedMode: AnimatedTranslationMode.posterFrame, regions: const []);
  }
  @override
  Future<void> unload() async { events.add('unload'); }
}

final class _Translator implements ComicTextTranslationEngine {
  @override
  ComicTranslationContextMode get contextMode => ComicTranslationContextMode.none;
  @override
  ComicTranslationEngineIdentity identityFor(ComicTranslationRequest request) =>
      const ComicTranslationEngineIdentity(id: 'unused', modelVersion: '1');
  @override
  Future<void> load() async {}
  @override
  Future<ComicTranslationResult> translate(ComicTranslationRequest request) async =>
      const ComicTranslationResult({});
  @override
  Future<void> unload() async {}
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:comic_translation/src/benchmark.dart';
import 'package:comic_translation/src/bubble_boundary.dart';
import 'package:comic_translation/src/deepl_translation.dart';
import 'package:comic_translation/src/engine.dart';
import 'package:comic_translation/src/grouping.dart';
import 'package:comic_translation/src/http_client.dart';
import 'package:comic_translation/src/input_resolver.dart';
import 'package:comic_translation/src/models.dart';
import 'package:comic_translation/src/ocr_parameters.dart';
import 'package:comic_translation/src/policy.dart';
import 'package:comic_translation/src/remote_translation.dart';
import 'package:comic_translation/src/runtime.dart';
import 'package:comic_translation/src/session.dart';
import 'package:comic_translation/src/store.dart';

void main() {
  late Directory temp;

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('venera-translation-test');
    await ComicTranslationStore.instance.init(temp.path);
  });

  tearDownAll(() async {
    await ComicTranslationStore.instance.close();
    await temp.delete(recursive: true);
  });

  test('portable page results restore after database clear without OCR or translation', () async {
    final image = File('${temp.path}/portable-page.bin');
    await image.writeAsBytes([31, 71, 92]);
    final identity = ComicTranslationPageIdentity(imageKey: image.uri.toString(),
      sourceKey: 'archive', comicId: 'comic', chapterId: 'chapter', pageIndex: 0,
      mediaKind: ComicTranslationMediaKind.staticImage);
    final ocr = _OcrEngine(version: 'archive-v1');
    final translator = _TranslationEngine();
    final registry = ComicTranslationEngineRegistry()
      ..ocrEngine = ocr..translationEngine = translator;
    Uint8List? saved;
    final events = <Map<String, Object?>>[];
    ComicTranslationSession create({ComicTranslationPolicy policy = const ComicTranslationPolicy(),
        String sourceLanguage = 'ja'}) =>
      ComicTranslationSession(enabled: true, sourceLanguage: sourceLanguage, targetLanguage: 'zh-CN',
        engines: registry, policy: policy, onDiagnostic: (_, event) => events.add(event),
        inputResolver: ComicTranslationInputResolver(openFile: (_) async => ComicTranslationInputFile(
          path: image.path, release: () {}, archive: ComicTranslationArchiveAccess(
            read: () async => saved, write: (bytes) async => saved = bytes))));
    Future<ComicTranslationPageState> run(ComicTranslationSession session) async {
      session.reportPages(current: [identity], interaction: ComicTranslationInteraction.idle);
      await _waitFor(session, identity);
      final state = session.listenable(identity).value;
      await session.close();
      return state;
    }

    final original = await run(create());
    expect(saved, isNotNull);
    expect(ocr.calls, 1);
    expect(translator.calls, 1);
    await ComicTranslationStore.instance.clear();
    final restored = await run(create());
    expect(restored.artifact!.toJson(), original.artifact!.toJson());
    expect(restored.cleanOverlayPng, original.cleanOverlayPng);
    expect(ocr.calls, 1);
    expect(translator.calls, 1);
    expect(ocr.loads, 1, reason: 'archive restoration must not load a model');
    expect(events.any((event) => event['stage'] == 'archive-restored'), isTrue);
    await ComicTranslationStore.instance.clear();
    await run(create(sourceLanguage: 'auto'));
    expect(ocr.calls, 1, reason: 'a validated single saved language can restore automatic mode');
    expect(translator.calls, 1);

    await run(create(policy: const ComicTranslationPolicy(
      ocrParameters: ComicOcrParameters(recognitionThreshold: 0.6))));
    expect(ocr.calls, 2, reason: 'saved results cannot bypass changed OCR configuration');
    expect(translator.calls, 2);
    await image.writeAsBytes([31, 71, 93]);
    await run(create());
    expect(ocr.calls, 3, reason: 'the actual image digest must reject the former page archive');
    expect(translator.calls, 3);
    expect(events.any((event) => event['stage'] == 'archive-read-failed'), isTrue);
  });

  test('page archive bytes stay stable when only variant access order changes', () async {
    const content = 'stable-page-archive';
    final store = ComicTranslationStore.instance;
    final results = <ComicTranslationArtifact>[];
    for (var index = 0; index < 2; index++) {
      final ocr = ComicOcrArtifact(contentDigest: content, engineId: 'stable-ocr',
        modelVersion: 'v$index', sourceLanguage: 'ja', imageWidth: 20, imageHeight: 30,
        mediaKind: ComicTranslationMediaKind.staticImage,
        animatedMode: AnimatedTranslationMode.posterFrame, regions: const []);
      final digest = await store.storeOcr(ocr);
      final result = ComicTranslationArtifact(contentDigest: content, ocrDigest: digest,
        engineId: 'stable-translator', modelVersion: 'v1', sourceLanguage: 'ja',
        targetLanguage: 'zh-CN', contextDigest: '$index', imageWidth: 20, imageHeight: 30,
        mediaKind: ComicTranslationMediaKind.staticImage,
        animatedMode: AnimatedTranslationMode.posterFrame, regions: const []);
      results.add(result);
      await store.storeTranslation(result);
    }
    final original = (await store.exportPage(content))!;
    for (var index = 0; index < results.length; index++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final result = results[index];
      await store.findOcr(contentDigest: content, engineId: 'stable-ocr',
        modelVersion: 'v$index', sourceLanguage: 'ja');
      await store.findTranslation(ocrDigest: result.ocrDigest, engineId: result.engineId,
        modelVersion: result.modelVersion, targetLanguage: result.targetLanguage,
        contextDigest: result.contextDigest);
      expect(await store.exportPage(content), original,
        reason: 'reading an unchanged variant must not rewrite a downloaded companion');
    }
    for (var index = 2; index < 10; index++) {
      final result = ComicTranslationArtifact.fromJson({
        ...results.first.toJson(), 'contextDigest': '$index',
      });
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await store.storeTranslation(result);
    }
    final changed = (await store.exportPage(content))!;
    expect(changed, isNot(original));
    final envelope = jsonDecode(utf8.decode(changed)) as Map;
    final variants = (envelope['translations'] as List)
        .map((payload) => jsonDecode(payload as String) as Map).toList();
    expect(variants, hasLength(8));
    expect(variants.map((variant) => variant['contextDigest']).toSet(),
      {for (var index = 2; index < 10; index++) '$index'},
      reason: 'stable serialization still selects the eight most recent variants');
  });

  test('archive validation rejects a corrupt batch before inserting any result', () async {
    final image = File('${temp.path}/archive-validation.bin');
    await image.writeAsBytes([62, 17, 82]);
    final identity = ComicTranslationPageIdentity(imageKey: image.uri.toString(),
      sourceKey: 'archive-validation', comicId: 'comic', chapterId: 'chapter', pageIndex: 0,
      mediaKind: ComicTranslationMediaKind.staticImage);
    final session = ComicTranslationSession(enabled: true, sourceLanguage: 'ja', targetLanguage: 'zh-CN',
      engines: ComicTranslationEngineRegistry()..ocrEngine = _OcrEngine()..translationEngine = _TranslationEngine());
    session.reportPages(current: [identity], interaction: ComicTranslationInteraction.idle);
    await _waitFor(session, identity);
    final artifact = session.listenable(identity).value.artifact!;
    await session.close();
    final bytes = (await ComicTranslationStore.instance.exportPage(artifact.contentDigest))!;
    await ComicTranslationStore.instance.clear();
    final envelope = jsonDecode(utf8.decode(bytes)) as Map;
    final invalid = Map<String, dynamic>.from(artifact.toJson())..['contentDigest'] = 'other';
    (envelope['translations'] as List).add(jsonEncode(invalid));
    await expectLater(ComicTranslationStore.instance.restorePage(
      Uint8List.fromList(utf8.encode(jsonEncode(envelope))), contentDigest: artifact.contentDigest), throwsStateError);
    expect(await ComicTranslationStore.instance.findTranslation(ocrDigest: artifact.ocrDigest,
      engineId: artifact.engineId, modelVersion: artifact.modelVersion,
      targetLanguage: artifact.targetLanguage, contextDigest: artifact.contextDigest), isNull);
    await expectLater(ComicTranslationStore.instance.restorePage(bytes,
      contentDigest: 'different-image'), throwsStateError);
    (envelope['translations'] as List).removeLast();
    final ocr = envelope['ocr'] as Map;
    ocr[ocr.keys.first] = '${ocr.values.first} ';
    await expectLater(ComicTranslationStore.instance.restorePage(
      Uint8List.fromList(utf8.encode(jsonEncode(envelope))), contentDigest: artifact.contentDigest), throwsStateError);
    expect(await ComicTranslationStore.instance.restorePage(bytes, contentDigest: artifact.contentDigest), 1);
  });

  test('chapter task shares models and reuses results with a bounded context', () async {
    final pages = <ComicTranslationPageIdentity>[];
    for (var index = 0; index < 5; index++) {
      final image = File('${temp.path}/chapter-task-$index.bin');
      await image.writeAsBytes([17, 42, index]);
      pages.add(ComicTranslationPageIdentity(imageKey: image.uri.toString(),
        sourceKey: 'chapter-task', comicId: 'comic', chapterId: 'chapter',
        pageIndex: index, mediaKind: ComicTranslationMediaKind.staticImage));
    }
    final ocr = _OcrEngine(version: 'chapter-task-v1');
    final translator = _TranslationEngine();
    final registry = ComicTranslationEngineRegistry()
      ..ocrEngine = ocr..translationEngine = translator;
    for (var run = 0; run < 2; run++) {
      final task = ComicTranslationChapterTask(pages: pages,
        sourceLanguage: 'ja', targetLanguage: 'zh-CN', engines: registry,
        inputResolver: const ComicTranslationInputResolver());
      await task.completion.timeout(const Duration(seconds: 10));
      expect(task.state.value.phase, ComicTranslationChapterPhase.complete);
      expect(task.state.value.completedPages, 5);
      expect(ocr.calls, 5);
      expect(translator.calls, 5, reason: 'a repeated chapter task reads persisted results');
      expect(translator.lastRequest!.previousPages.map((page) => page.pageIndex), [2, 3]);
      await task.close();
    }
    expect(ocr.loads, 1);
    expect(translator.loads, 1);
    expect(ocr.unloads, 1);
    expect(translator.unloads, 1);
  });

  test('chapter cancellation drains the in-flight model and never starts the next page', () async {
    final pages = <ComicTranslationPageIdentity>[];
    for (var index = 0; index < 2; index++) {
      final image = File('${temp.path}/chapter-cancel-$index.bin');
      await image.writeAsBytes([43, 12, index]);
      pages.add(ComicTranslationPageIdentity(imageKey: image.uri.toString(),
        sourceKey: 'chapter-cancel', comicId: 'comic', chapterId: 'chapter',
        pageIndex: index, mediaKind: ComicTranslationMediaKind.staticImage));
    }
    final started = Completer<void>();
    final gate = Completer<void>();
    final ocr = _OcrEngine(version: 'chapter-cancel-v1');
    final translator = _TranslationEngine(translateStarted: started, translateGate: gate);
    final registry = ComicTranslationEngineRegistry()
      ..ocrEngine = ocr..translationEngine = translator;
    final task = ComicTranslationChapterTask(pages: pages,
      sourceLanguage: 'ja', targetLanguage: 'zh-CN', engines: registry,
      inputResolver: const ComicTranslationInputResolver());
    await started.future;
    var drained = false;
    final cancellation = task.cancel().then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(task.state.value.phase, ComicTranslationChapterPhase.cancelling);
    expect(drained, isFalse);
    expect(ocr.unloads, 0);
    expect(translator.unloads, 0);
    gate.complete();
    await cancellation;
    expect(task.state.value.phase, ComicTranslationChapterPhase.cancelled);
    expect(ocr.calls, 1);
    expect(translator.calls, 1);
    expect(ocr.unloads, 1);
    expect(translator.unloads, 1);
    await task.close();
  });

  test('chapter cache hits drain page archive leases before advancing or cancelling', () async {
    final pages = <ComicTranslationPageIdentity>[];
    for (var index = 0; index < 2; index++) {
      final file = File('${temp.path}/chapter-archive-$index.bin');
      await file.writeAsBytes([71, 39, index]);
      pages.add(ComicTranslationPageIdentity(imageKey: file.uri.toString(),
        sourceKey: 'chapter-archive', comicId: 'comic', chapterId: 'chapter',
        pageIndex: index, mediaKind: ComicTranslationMediaKind.staticImage));
    }
    final entered = Completer<void>();
    final gate = Completer<void>();
    var opened = 0;
    var released = 0;
    final ocr = _OcrEngine(version: 'chapter-archive-v1');
    final translator = _TranslationEngine();
    final registry = ComicTranslationEngineRegistry()
      ..ocrEngine = ocr..translationEngine = translator;
    final warm = ComicTranslationChapterTask(pages: [pages.first],
      sourceLanguage: 'ja', targetLanguage: 'zh-CN', engines: registry,
      inputResolver: const ComicTranslationInputResolver());
    await warm.completion;
    await warm.close();
    final task = ComicTranslationChapterTask(pages: pages,
      sourceLanguage: 'ja', targetLanguage: 'zh-CN',
      engines: registry,
      inputResolver: ComicTranslationInputResolver(openFile: (identity) async {
        opened++;
        return ComicTranslationInputFile(path: File.fromUri(Uri.parse(identity.imageKey)).path,
          release: () => released++, archive: ComicTranslationArchiveAccess(
            read: () async => null, write: (_) async {
              if (!entered.isCompleted) entered.complete();
              await gate.future;
            }));
      }));
    await entered.future;
    expect(opened, 1);
    expect(task.state.value.completedPages, 0);
    var drained = false;
    final cancelling = task.cancel().then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);
    expect(released, 0);
    expect(ocr.unloads, 1);
    gate.complete();
    await cancelling;
    expect(task.state.value.phase, ComicTranslationChapterPhase.cancelled);
    expect(opened, 1);
    expect(released, 1);
    expect(ocr.calls, 1);
    expect(translator.calls, 1);
    await task.close();
  });

  test('chapter task reports a missing complete input without hanging', () async {
    final task = ComicTranslationChapterTask(pages: const [
      ComicTranslationPageIdentity(imageKey: 'not-downloaded', sourceKey: 'missing',
        comicId: 'comic', chapterId: 'chapter', pageIndex: 0,
        mediaKind: ComicTranslationMediaKind.staticImage),
    ], sourceLanguage: 'ja', targetLanguage: 'zh-CN',
      inputResolver: ComicTranslationInputResolver(openFile: (_) async => null),
      engines: ComicTranslationEngineRegistry()
        ..ocrEngine = _OcrEngine()..translationEngine = _TranslationEngine());
    await task.completion.timeout(const Duration(seconds: 5));
    expect(task.state.value.phase, ComicTranslationChapterPhase.failed);
    expect(task.state.value.completedPages, 0);
    expect(task.state.value.error, isA<StateError>());
    await task.close();
  });

  test('Reader and chapter work share identical inference through cancellation', () async {
    final image = File('${temp.path}/chapter-reader-shared.bin');
    await image.writeAsBytes([70, 19, 82]);
    final identity = ComicTranslationPageIdentity(imageKey: image.uri.toString(),
      sourceKey: 'chapter-reader', comicId: 'comic', chapterId: 'chapter', pageIndex: 0,
      mediaKind: ComicTranslationMediaKind.staticImage);
    final ocrStarted = Completer<void>();
    final ocrGate = Completer<void>();
    final mtGate = Completer<void>();
    final sharedOcr = Completer<void>();
    final sharedMt = Completer<void>();
    void diagnostic(ComicTranslationPageIdentity _, Map<String, Object?> event) {
      if (event['stage'] == 'ocr-shared' && !sharedOcr.isCompleted) sharedOcr.complete();
      if (event['stage'] == 'translation-shared' && !sharedMt.isCompleted) sharedMt.complete();
    }
    final ocr = _OcrEngine(version: 'chapter-reader-shared-v1',
      recognizeStarted: ocrStarted, recognizeGate: ocrGate);
    final translator = _TranslationEngine(translateGate: mtGate);
    final registry = ComicTranslationEngineRegistry()
      ..ocrEngine = ocr..translationEngine = translator;
    final reader = ComicTranslationSession(enabled: true, sourceLanguage: 'ja', targetLanguage: 'zh-CN',
      engines: registry, onDiagnostic: diagnostic);
    reader.reportPages(current: [identity], interaction: ComicTranslationInteraction.idle);
    await ocrStarted.future;
    final task = ComicTranslationChapterTask(pages: [identity], sourceLanguage: 'ja',
      targetLanguage: 'zh-CN', engines: registry, onDiagnostic: diagnostic,
      inputResolver: const ComicTranslationInputResolver());
    await sharedOcr.future.timeout(const Duration(seconds: 5));
    ocrGate.complete();
    await sharedMt.future.timeout(const Duration(seconds: 5));
    var cancelled = false;
    final cancellation = task.cancel().then((_) => cancelled = true);
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, isFalse);
    mtGate.complete();
    await cancellation;
    expect((await _waitFor(reader, identity)).artifact!.regions.single.translatedText, '你好');
    expect(ocr.calls, 1);
    expect(translator.calls, 1);
    expect(task.state.value.phase, ComicTranslationChapterPhase.cancelled);
    await task.close();
    await reader.close();
    expect(ocr.unloads, 1);
    expect(translator.unloads, 1);
  });

  test('chapter cancellation interrupts HTTP backoff and never opens the next page', () async {
    final image = File('${temp.path}/chapter-http-cancel.bin');
    await image.writeAsBytes([88, 31, 9]);
    final identity = ComicTranslationPageIdentity(imageKey: image.uri.toString(),
      sourceKey: 'http-cancel', comicId: 'comic', chapterId: 'chapter', pageIndex: 0,
      mediaKind: ComicTranslationMediaKind.staticImage);
    final retrying = Completer<void>();
    final adapter = _DeepLAdapter.generated((options) => throw DioException(
      requestOptions: options, error: const HandshakeException('Connection terminated during handshake')));
    final previousAdapter = ComicTranslationHttp.adapterFactory;
    ComicTranslationHttp.adapterFactory = () => adapter;
    addTearDown(() => ComicTranslationHttp.adapterFactory = previousAdapter);
    final ocr = _OcrEngine(version: 'http-cancel-v1');
    final registry = ComicTranslationEngineRegistry()..ocrEngine = ocr
      ..translationEngine = OpenAiCompatibleComicTranslationEngine(
        endpoint: 'https://example.com/v1/chat/completions', model: 'test', apiKey: '');
    var opened = 0;
    var released = 0;
    final task = ComicTranslationChapterTask(pages: [identity, identity],
      sourceLanguage: 'ja', targetLanguage: 'zh-CN', engines: registry,
      inputResolver: ComicTranslationInputResolver(openFile: (_) async {
        opened++;
        return ComicTranslationInputFile(path: image.path, release: () => released++);
      }), onDiagnostic: (_, event) {
        if (event['stage'] == 'translation-retry' && !retrying.isCompleted) retrying.complete();
      });
    await retrying.future.timeout(const Duration(seconds: 5));
    expect(task.state.value.retry?.attempt, 1);
    await task.cancel().timeout(const Duration(seconds: 1));
    expect(task.state.value.phase, ComicTranslationChapterPhase.cancelled);
    expect(task.state.value.retry, isNull);
    expect(adapter.requests, hasLength(1));
    expect(opened, 1);
    expect(released, 1);
    expect(ocr.unloads, 1);
    await task.close();
  });

  for (final cancelChapter in [false, true]) {
    test('HTTP backoff survives a shared ${cancelChapter ? 'chapter' : 'Reader'} cancellation', () async {
      final image = File('${temp.path}/shared-http-$cancelChapter.bin');
      await image.writeAsBytes([89, 32, cancelChapter ? 1 : 0]);
      final identity = ComicTranslationPageIdentity(imageKey: image.uri.toString(),
        sourceKey: 'shared-http-$cancelChapter', comicId: 'comic', chapterId: 'chapter', pageIndex: 0,
        mediaKind: ComicTranslationMediaKind.staticImage);
      final retrying = Completer<void>();
      final shared = Completer<void>();
      var calls = 0;
      final adapter = _DeepLAdapter.generated((options) {
        if (++calls == 1) throw DioException(requestOptions: options,
          error: const HandshakeException('Connection terminated during handshake'));
        return {'translations': {'u0': ['你好']}};
      });
      final previousAdapter = ComicTranslationHttp.adapterFactory;
      ComicTranslationHttp.adapterFactory = () => adapter;
      addTearDown(() => ComicTranslationHttp.adapterFactory = previousAdapter);
      final ocr = _OcrEngine(version: 'shared-http-$cancelChapter-v1');
      final registry = ComicTranslationEngineRegistry()..ocrEngine = ocr
        ..translationEngine = OpenAiCompatibleComicTranslationEngine(
          endpoint: 'https://example.com/v1/chat/completions', model: 'test', apiKey: '');
      void diagnostic(ComicTranslationPageIdentity _, Map<String, Object?> event) {
        if (event['stage'] == 'translation-retry' && !retrying.isCompleted) retrying.complete();
        if (event['stage'] == 'translation-shared' && !shared.isCompleted) shared.complete();
      }
      final reader = ComicTranslationSession(enabled: true, sourceLanguage: 'ja',
        targetLanguage: 'zh-CN', engines: registry, onDiagnostic: diagnostic);
      reader.reportPages(current: [identity], interaction: ComicTranslationInteraction.idle);
      await retrying.future.timeout(const Duration(seconds: 5));
      final task = ComicTranslationChapterTask(pages: [identity], sourceLanguage: 'ja',
        targetLanguage: 'zh-CN', engines: registry, onDiagnostic: diagnostic,
        inputResolver: const ComicTranslationInputResolver());
      await shared.future.timeout(const Duration(seconds: 5));
      expect(task.state.value.retry?.attempt, 1, reason: 'late joiners see the active retry');
      if (cancelChapter) {
        final cancelled = task.cancel();
        expect((await _waitFor(reader, identity)).artifact?.regions.single.translatedText, '你好');
        await cancelled;
        expect(task.state.value.phase, ComicTranslationChapterPhase.cancelled);
      } else {
        reader.setEnabled(false);
        await task.completion.timeout(const Duration(seconds: 5));
        expect(task.state.value.phase, ComicTranslationChapterPhase.complete);
        expect(task.state.value.completedPages, 1);
        expect(reader.listenable(identity).value.phase, ComicTranslationPhase.disabled);
      }
      expect(calls, 2);
      expect(ocr.calls, 1);
      await task.close();
      await reader.close();
      expect(ocr.unloads, 1);
    });
  }

  test('background entry wakes HTTP backoff and resumes from cached OCR', () async {
    final image = File('${temp.path}/background-http.bin');
    await image.writeAsBytes([90, 33, 8]);
    final identity = ComicTranslationPageIdentity(imageKey: image.uri.toString(),
      sourceKey: 'background-http', comicId: 'comic', chapterId: 'chapter', pageIndex: 0,
      mediaKind: ComicTranslationMediaKind.staticImage);
    final retrying = Completer<void>();
    var calls = 0;
    final adapter = _DeepLAdapter.generated((options) {
      if (++calls == 1) throw DioException(requestOptions: options,
        type: DioExceptionType.connectionError);
      return {'translations': {'u0': ['你好']}};
    });
    final previousAdapter = ComicTranslationHttp.adapterFactory;
    ComicTranslationHttp.adapterFactory = () => adapter;
    addTearDown(() => ComicTranslationHttp.adapterFactory = previousAdapter);
    final ocr = _OcrEngine(version: 'background-http-v1');
    final registry = ComicTranslationEngineRegistry()..ocrEngine = ocr
      ..translationEngine = OpenAiCompatibleComicTranslationEngine(
        endpoint: 'https://example.com/v1/chat/completions', model: 'test', apiKey: '');
    final task = ComicTranslationChapterTask(pages: [identity], sourceLanguage: 'ja',
      targetLanguage: 'zh-CN', engines: registry,
      inputResolver: const ComicTranslationInputResolver(), onDiagnostic: (_, event) {
        if (event['stage'] == 'translation-retry' && !retrying.isCompleted) retrying.complete();
      });
    await retrying.future.timeout(const Duration(seconds: 5));
    await registry.setBackground(true).timeout(const Duration(seconds: 1));
    expect(calls, 1);
    expect(ocr.unloads, 1);
    expect(task.state.value.phase, ComicTranslationChapterPhase.running);
    await registry.setBackground(false);
    await task.completion.timeout(const Duration(seconds: 5));
    expect(task.state.value.phase, ComicTranslationChapterPhase.complete);
    expect(calls, 2);
    expect(ocr.calls, 1);
    await task.close();
  });

  for (final returnImmediately in [false, true]) {
    test('page demand retires stale HTTP backoff with immediate return $returnImmediately', () async {
      final pages = <ComicTranslationPageIdentity>[];
      for (var index = 0; index < 2; index++) {
        final image = File('${temp.path}/http-demand-$returnImmediately-$index.bin');
        await image.writeAsBytes([91, returnImmediately ? 1 : 0, index]);
        pages.add(ComicTranslationPageIdentity(imageKey: image.uri.toString(),
          sourceKey: 'http-demand-$returnImmediately', comicId: 'comic', chapterId: 'chapter',
          pageIndex: index, mediaKind: ComicTranslationMediaKind.staticImage));
      }
      final retrying = Completer<void>();
      var calls = 0;
      final adapter = _DeepLAdapter.generated((options) {
        if (++calls == 1) throw DioException(requestOptions: options,
          type: DioExceptionType.connectionError);
        return {'translations': {'u0': ['你好']}};
      });
      final previousAdapter = ComicTranslationHttp.adapterFactory;
      ComicTranslationHttp.adapterFactory = () => adapter;
      addTearDown(() => ComicTranslationHttp.adapterFactory = previousAdapter);
      final ocr = _OcrEngine(version: 'http-demand-$returnImmediately-v1');
      final registry = ComicTranslationEngineRegistry()..ocrEngine = ocr
        ..translationEngine = OpenAiCompatibleComicTranslationEngine(
          endpoint: 'https://example.com/v1/chat/completions', model: 'test', apiKey: '');
      final reader = ComicTranslationSession(enabled: true, sourceLanguage: 'ja',
        targetLanguage: 'zh-CN', engines: registry,
        policy: const ComicTranslationPolicy(prefetchPages: 0, cachePrefetchPages: 0),
        onDiagnostic: (_, event) {
          if (event['stage'] == 'translation-retry' && !retrying.isCompleted) retrying.complete();
        });
      reader.reportPages(current: [pages.first], interaction: ComicTranslationInteraction.idle);
      await retrying.future.timeout(const Duration(seconds: 5));
      reader.reportPages(current: [pages.last], interaction: ComicTranslationInteraction.idle);
      if (returnImmediately) reader.reportPages(current: [pages.first],
        interaction: ComicTranslationInteraction.idle);
      final target = returnImmediately ? pages.first : pages.last;
      final ready = await _waitFor(reader, target).timeout(const Duration(seconds: 1));
      expect(ready.artifact?.regions.single.translatedText, '你好');
      expect(calls, 2);
      expect(ocr.calls, returnImmediately ? 1 : 2);
      await reader.close();
    });
  }

  test('static page is recognized, translated and reused by content digest', () async {
    final image = File('${temp.path}/page.bin');
    await image.writeAsBytes(List<int>.generate(256, (i) => i));
    final identity = ComicTranslationPageIdentity(
      imageKey: image.uri.toString(),
      sourceKey: 'local',
      comicId: 'comic',
      chapterId: 'chapter',
      pageIndex: 0,
      mediaKind: ComicTranslationMediaKind.staticImage,
    );
    final ocr = _OcrEngine();
    final translator = _TranslationEngine();
    final registry = ComicTranslationEngineRegistry()
      ..ocrEngine = ocr
      ..translationEngine = translator;
    final first = ComicTranslationSession(
      enabled: true,
      sourceLanguage: 'ja',
      targetLanguage: 'zh-CN',
      engines: registry,
    );
    first.reportPages(
      current: [identity],
      interaction: ComicTranslationInteraction.idle,
    );
    final firstState = await _waitFor(first, identity);
    expect(firstState.artifact!.regions.single.translatedText, '你好');
    expect(firstState.artifact!.regions.single.backgroundArgb, 0xFFFFFFFF);
    expect(firstState.artifact!.regions.single.foregroundArgb, 0xFF202020);
    expect(firstState.artifact!.regions.single.bubbleGroupId, 3);
    expect(firstState.cleanOverlayPng, [1, 2, 3]);
    expect(firstState.artifact!.ocrDigest, translator.lastRequest!.ocr.digest,
      reason: 'worker preparation must preserve the existing content-cache identity');
    expect(firstState.artifact!.regions.single.bubblePolygon, isNotEmpty);
    expect(firstState.artifact!.regions.single.bubbleCandidatePolygon, isNotEmpty);
    expect(firstState.artifact!.regions.single.sourceMaskPolygons.single, hasLength(4));
    expect(ocr.calls, 1);
    expect(translator.calls, 1);
    first.setEnabled(false);
    first.setEnabled(true);
    first.reportPages(
      current: [identity],
      interaction: ComicTranslationInteraction.idle,
    );
    await _waitFor(first, identity);
    expect(ocr.calls, 1);
    expect(translator.calls, 1);
    await first.close();
    await ComicTranslationStore.instance.close();
    await ComicTranslationStore.instance.init(temp.path);

    final second = ComicTranslationSession(
      enabled: true,
      sourceLanguage: 'ja',
      targetLanguage: 'zh-CN',
      engines: registry,
    );
    second.reportPages(
      current: [identity],
      interaction: ComicTranslationInteraction.idle,
    );
    final secondState = await _waitFor(second, identity);
    expect(
      secondState.artifact!.regions.single.sourceMaskPolygons.single.first.x,
      0.12,
    );
    expect(secondState.artifact!.regions.single.foregroundArgb, 0xFF202020);
    expect(secondState.artifact!.regions.single.bubbleGroupId, 3);
    expect(secondState.artifact!.regions.single.bubbleCandidatePolygon, isNotEmpty);
    expect(secondState.cleanOverlayPng, [1, 2, 3]);
    expect(ocr.calls, 1);
    expect(translator.calls, 1);
    second.dispose();

    final fallback = ComicTranslationSession(
      enabled: true,
      sourceLanguage: 'ja',
      targetLanguage: 'zh-CN',
      engines: registry,
      policy: const ComicTranslationPolicy(useCleanOverlay: false),
    );
    fallback.reportPages(
      current: [identity],
      interaction: ComicTranslationInteraction.idle,
    );
    final fallbackState = await _waitFor(fallback, identity);
    expect(fallbackState.cleanOverlayPng, isNull);
    expect(fallbackState.artifact, isNotNull);
    fallback.dispose();
  });

  test('repeated viewport observations preserve the active OCR phase', () async {
    final image = File('${temp.path}/active-ocr.bin');
    await image.writeAsBytes(List<int>.filled(267, 19));
    final identity = ComicTranslationPageIdentity(imageKey: image.uri.toString(), sourceKey: 'active',
      comicId: 'comic', chapterId: 'chapter', pageIndex: 0, mediaKind: ComicTranslationMediaKind.staticImage);
    final started = Completer<void>();
    final gate = Completer<void>();
    final ocr = _OcrEngine(recognizeStarted: started, recognizeGate: gate);
    final registry = ComicTranslationEngineRegistry()..ocrEngine = ocr..translationEngine = _TranslationEngine();
    final session = ComicTranslationSession(enabled: true, sourceLanguage: 'ja', targetLanguage: 'zh-CN', engines: registry);
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await session.close();
    });
    session.reportPages(current: [identity], interaction: ComicTranslationInteraction.idle);
    await started.future;
    for (var i = 0; i < 3; i++) {
      session.reportPages(current: [identity], interaction: ComicTranslationInteraction.idle);
      expect(session.listenable(identity).value.phase, ComicTranslationPhase.recognizing);
    }
    gate.complete();
    await _waitFor(session, identity);
    expect(ocr.calls, 1);
  });

  test('repeated observations claim a cached page before awaiting a probe', () async {
    final image = File('${temp.path}/cache-claim.bin');
    await image.writeAsBytes(List<int>.filled(593, 73));
    ComicTranslationPageIdentity page(int index) => ComicTranslationPageIdentity(
      imageKey: image.uri.toString(), sourceKey: 'cache-claim', comicId: 'comic',
      chapterId: 'chapter', pageIndex: index, mediaKind: ComicTranslationMediaKind.staticImage);
    final first = page(0);
    final second = page(1);
    final ocr = _OcrEngine();
    final translator = _TranslationEngine(contextMode: ComicTranslationContextMode.none);
    final events = <Map<String, Object?>>[];
    var secondInputs = 0;
    final session = ComicTranslationSession(enabled: true, sourceLanguage: 'ja', targetLanguage: 'zh-CN',
      engines: ComicTranslationEngineRegistry()..ocrEngine = ocr..translationEngine = translator,
      inputResolver: ComicTranslationInputResolver(openFile: (identity) async {
        if (identity == second) secondInputs++;
        return ComicTranslationInputFile(path: image.path, release: () {});
      }),
      onDiagnostic: (identity, details) { if (identity == second) events.add(details); });
    addTearDown(session.close);
    session.reportPages(current: [first], interaction: ComicTranslationInteraction.idle);
    await _waitFor(session, first);
    await Future<void>.delayed(Duration.zero);
    for (var i = 0; i < 2; i++) {
      session.reportPages(current: [second], interaction: ComicTranslationInteraction.idle);
    }
    await _waitFor(session, second);
    await session.close();
    expect(secondInputs, 1, reason: 'the serial owner must be claimed before a repeated observation can probe');
    expect(ocr.calls, 1);
    expect(translator.calls, 1);
    expect(events.where((event) => event['stage'] == 'ready'), hasLength(1),
      reason: 'a late cache probe must not replace the same visible artifact a second time');
  });

  test('cached neighbors are ready before current inference exits', () async {
    final pages = <ComicTranslationPageIdentity>[];
    for (var i = 0; i < 2; i++) {
      final image = File('${temp.path}/neighbor-cache-$i.bin');
      await image.writeAsBytes(List<int>.filled(457 + i, 91));
      pages.add(ComicTranslationPageIdentity(imageKey: image.uri.toString(), sourceKey: 'neighbors',
        comicId: 'comic', chapterId: 'chapter', pageIndex: i,
        mediaKind: ComicTranslationMediaKind.staticImage));
    }
    final seed = ComicTranslationSession(enabled: true, sourceLanguage: 'ja', targetLanguage: 'zh-CN',
      engines: ComicTranslationEngineRegistry()..ocrEngine = _OcrEngine()..translationEngine = _TranslationEngine());
    seed.reportPages(current: [pages.last], interaction: ComicTranslationInteraction.idle);
    await _waitFor(seed, pages.last);
    final expectedScale = seed.fontScaleListenable.value;
    await seed.close();
    final started = Completer<void>();
    final gate = Completer<void>();
    final translator = _TranslationEngine(translateStarted: started, translateGate: gate);
    final opened = <ComicTranslationPageIdentity>[];
    final session = ComicTranslationSession(enabled: true, sourceLanguage: 'ja', targetLanguage: 'zh-CN',
      engines: ComicTranslationEngineRegistry()..ocrEngine = _OcrEngine()..translationEngine = translator,
      inputResolver: ComicTranslationInputResolver(openFile: (identity) async {
        opened.add(identity);
        return ComicTranslationInputFile(path: File.fromUri(Uri.parse(identity.imageKey)).path,
          release: () {});
      }));
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await session.close();
    });
    session.reportPages(current: [pages.first], near: [pages.last], interaction: ComicTranslationInteraction.idle);
    expect(opened.first, pages.first, reason: 'current input must start before speculative cache reads');
    await started.future.timeout(const Duration(seconds: 2));
    final prepared = await _waitFor(session, pages.last).timeout(const Duration(seconds: 2));
    expect(gate.isCompleted, isFalse);
    expect(session.fontScaleListenable.value, 1,
      reason: 'a speculative cache hit cannot choose the visible page typography');
    session.reportPages(current: [pages.last], interaction: ComicTranslationInteraction.dragging);
    expect(session.listenable(pages.last).value.artifact, same(prepared.artifact));
    expect(session.fontScaleListenable.value, expectedScale);
    expect(translator.calls, 1, reason: 'a cached neighbor must not enter the model queue');
  });

  for (final cacheOnly in [false, true]) {
    for (final notifyWhileOpening in [false, true]) {
      test('neighbor image readiness survives ${notifyWhileOpening ? 'input preparation' : 'owner cleanup'} '
          'for ${cacheOnly ? 'cache restoration' : 'inference'}', () async {
        final pages = <ComicTranslationPageIdentity>[];
        for (var i = 0; i < 2; i++) {
          final image = File('${temp.path}/image-ready-$cacheOnly-$notifyWhileOpening-$i.bin');
          await image.writeAsBytes(List<int>.filled(607 + i, 109 + (cacheOnly ? 1 : 0) + (notifyWhileOpening ? 2 : 0)));
          pages.add(ComicTranslationPageIdentity(imageKey: image.uri.toString(), sourceKey: 'image-ready',
            comicId: 'comic', chapterId: 'chapter', pageIndex: i,
            mediaKind: ComicTranslationMediaKind.staticImage));
        }
        if (cacheOnly) {
          final seed = ComicTranslationSession(enabled: true, sourceLanguage: 'ja', targetLanguage: 'zh-CN',
            engines: ComicTranslationEngineRegistry()..ocrEngine = _OcrEngine()
              ..translationEngine = _TranslationEngine(contextMode: ComicTranslationContextMode.none));
          seed.reportPages(current: [pages.last], interaction: ComicTranslationInteraction.idle);
          await _waitFor(seed, pages.last);
          await seed.close();
        }
        final opened = Completer<void>();
        final firstRead = Completer<ComicTranslationInputFile?>();
        final ocr = _OcrEngine();
        final translator = _TranslationEngine(contextMode: ComicTranslationContextMode.none);
        var neighborInputs = 0;
        final session = ComicTranslationSession(enabled: true, sourceLanguage: 'ja', targetLanguage: 'zh-CN',
          engines: ComicTranslationEngineRegistry()..ocrEngine = ocr..translationEngine = translator,
          policy: ComicTranslationPolicy(prefetchPages: cacheOnly ? 0 : 1, cachePrefetchPages: cacheOnly ? 1 : 0),
          inputResolver: ComicTranslationInputResolver(openFile: (identity) async {
            if (identity == pages.last && ++neighborInputs == 1) {
              opened.complete();
              return firstRead.future;
            }
            return ComicTranslationInputFile(path: File.fromUri(Uri.parse(identity.imageKey)).path,
              release: () {});
          }));
        addTearDown(() async {
          if (!firstRead.isCompleted) firstRead.complete(null);
          await session.close();
        });
        var notified = false;
        final state = session.listenable(pages.last);
        void imageCompleted() {
          if (notified || state.value.phase != ComicTranslationPhase.waitingForImage) return;
          notified = true;
          // A completion can arrive synchronously with publication of a miss,
          // before the old cache probe or serial inference owner has exited.
          session.imageReady(pages.last);
        }
        if (!notifyWhileOpening) state.addListener(imageCompleted);
        session.reportPages(current: [pages.first], near: [pages.last], interaction: ComicTranslationInteraction.idle);
        await opened.future.timeout(const Duration(seconds: 2));
        if (notifyWhileOpening) {
          expect(state.value.phase, ComicTranslationPhase.loadingCache);
          session.imageReady(pages.last);
          session.imageReady(pages.last);
        }
        firstRead.complete(null);
        await _waitFor(session, pages.last).timeout(const Duration(seconds: 2));
        await _waitFor(session, pages.first).timeout(const Duration(seconds: 2));
        if (!notifyWhileOpening) state.removeListener(imageCompleted);
        final readyInputs = neighborInputs;
        session.imageReady(pages.last);
        expect(neighborInputs, readyInputs, reason: 'a repeated completion cannot restart a ready page');
        await session.close();
        expect(neighborInputs, inInclusiveRange(2, 3),
          reason: 'one completion must wake input preparation without another viewport report or polling');
        expect(ocr.calls, cacheOnly ? 1 : 2);
        expect(translator.calls, cacheOnly ? 1 : 2);
      });
    }
  }

  for (final disable in [false, true]) {
    test('pending image readiness does not revive ${disable ? 'disabled' : 'unretained'} translation', () async {
      final image = File('${temp.path}/retired-image-ready-$disable.bin');
      await image.writeAsBytes(List<int>.filled(619, disable ? 117 : 119));
      ComicTranslationPageIdentity page(int index) => ComicTranslationPageIdentity(
        imageKey: image.uri.toString(), sourceKey: 'retired-image-ready', comicId: 'comic',
        chapterId: 'chapter', pageIndex: index, mediaKind: ComicTranslationMediaKind.staticImage);
      final current = page(0);
      final neighbor = page(1);
      final opened = Completer<void>();
      final missed = Completer<void>();
      final firstRead = Completer<ComicTranslationInputFile?>();
      var neighborInputs = 0;
      final ocr = _OcrEngine();
      final translator = _TranslationEngine(contextMode: ComicTranslationContextMode.none);
      final session = ComicTranslationSession(enabled: true, sourceLanguage: 'ja', targetLanguage: 'zh-CN',
        engines: ComicTranslationEngineRegistry()..ocrEngine = ocr..translationEngine = translator,
        policy: const ComicTranslationPolicy(prefetchPages: 1, cachePrefetchPages: 0),
        inputResolver: ComicTranslationInputResolver(openFile: (identity) async {
          if (identity == neighbor) {
            neighborInputs++;
            if (!opened.isCompleted) opened.complete();
            return firstRead.future;
          }
          return ComicTranslationInputFile(path: image.path, release: () {});
        }), onDiagnostic: (identity, details) {
          if (identity == neighbor && details['stage'] == 'input-ready' && details['available'] == false) {
            missed.complete();
          }
        });
      addTearDown(() async {
        if (!firstRead.isCompleted) firstRead.complete(null);
        await session.close();
      });
      session.reportPages(current: [current], near: [neighbor], interaction: ComicTranslationInteraction.idle);
      await opened.future.timeout(const Duration(seconds: 2));
      session.imageReady(neighbor);
      if (disable) {
        session.setEnabled(false);
      } else {
        session.reportPages(current: [current], interaction: ComicTranslationInteraction.idle);
      }
      firstRead.complete(null);
      await missed.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(Duration.zero);
      expect(neighborInputs, 1);
      expect(ocr.calls, 1);
      expect(translator.calls, 1);
      await session.close();
    });
  }

  test('dragging restores cache before inference submission is allowed', () async {
    final image = File('${temp.path}/drag-cache.bin');
    await image.writeAsBytes(List<int>.filled(487, 97));
    final page = ComicTranslationPageIdentity(imageKey: image.uri.toString(), sourceKey: 'drag-cache',
      comicId: 'comic', chapterId: 'chapter', pageIndex: 0,
      mediaKind: ComicTranslationMediaKind.staticImage);
    final registry = ComicTranslationEngineRegistry()
      ..ocrEngine = _OcrEngine()..translationEngine = _TranslationEngine();
    final seed = ComicTranslationSession(enabled: true, sourceLanguage: 'ja', targetLanguage: 'zh-CN', engines: registry);
    seed.reportPages(current: [page], interaction: ComicTranslationInteraction.idle);
    await _waitFor(seed, page);
    await seed.close();
    final ocr = _OcrEngine();
    final translator = _TranslationEngine();
    registry.configure(ocrEngine: ocr, translationEngine: translator);
    final session = ComicTranslationSession(enabled: true, sourceLanguage: 'ja', targetLanguage: 'zh-CN',
      engines: registry, policy: const ComicTranslationPolicy(dragSubmissionDelay: Duration(days: 1)));
    addTearDown(session.close);
    session.reportPages(current: [page], interaction: ComicTranslationInteraction.dragging);
    await _waitFor(session, page).timeout(const Duration(seconds: 2));
    expect(ocr.calls, 0);
    expect(ocr.loads, 0);
    expect(translator.calls, 0);
  });

  test('each OCR parameter isolates results and default cache remains reusable', () async {
    final image = File('${temp.path}/analysis-options.bin');
    await image.writeAsBytes(List<int>.filled(491, 101));
    final page = ComicTranslationPageIdentity(imageKey: image.uri.toString(), sourceKey: 'analysis-options',
      comicId: 'comic', chapterId: 'chapter', pageIndex: 0,
      mediaKind: ComicTranslationMediaKind.staticImage);
    final ocr = _OcrEngine();
    final translator = _TranslationEngine();
    final registry = ComicTranslationEngineRegistry()..ocrEngine = ocr..translationEngine = translator;
    const parameters = [ComicOcrParameters(), ComicOcrParameters(maxAnalysisSide: 2240),
      ComicOcrParameters(detectionThreshold: .65), ComicOcrParameters(recognitionThreshold: .55),
      ComicOcrParameters(unclipRatio: 1.7)];
    final digests = <String>{};
    for (var pass = 0; pass < 2; pass++) {
      for (final options in parameters) {
        final session = ComicTranslationSession(enabled: true, sourceLanguage: 'ja', targetLanguage: 'zh-CN',
          engines: registry, policy: ComicTranslationPolicy(ocrParameters: options));
        session.reportPages(current: [page], interaction: ComicTranslationInteraction.idle);
        final result = await _waitFor(session, page);
        digests.add(result.artifact!.ocrDigest);
        await session.close();
      }
      expect(ocr.calls, parameters.length);
      expect(translator.calls, parameters.length);
    }
    expect(digests, hasLength(parameters.length));
    expect(ocr.inputs.map((input) => input.maxAnalysisSide), parameters.map((p) => p.maxAnalysisSide));
    expect(ocr.inputs.map((input) => input.parameters), orderedEquals(parameters));
  });

  test('open bubble explores nearby candidate after text grouping', () {
    final decision = exploreComicBubbleBoundary(
      inkBounds: const [Rect.fromLTWH(40, 40, 20, 40)],
      confirmedPolygons: const [],
      candidatePolygons: const [[
        Offset(20, 20), Offset(80, 20),
        Offset(80, 100), Offset(20, 100),
      ]],
    );
    expect(decision.initialOpen, isTrue);
    expect(decision.nearbyCandidates, 1);
    expect(decision.formedBoundary, isTrue);
    expect(decision.source, ComicBubbleBoundarySource.candidate);
    expect(decision.boundaryBounds!.width / decision.sourceBounds.width, 3);
  });

  test('connected bubble resolves a usable inner layout independently by axis',
      () {
    final bounds = comicBubbleInnerBounds(
      polygons: const [[
        Offset(20, 10), Offset(80, 10), Offset(80, 45), Offset(55, 45),
        Offset(55, 60), Offset(90, 60), Offset(90, 120), Offset(10, 120),
        Offset(10, 60), Offset(45, 60), Offset(45, 45), Offset(20, 45),
      ]],
      sourceBounds: const Rect.fromLTWH(40, 20, 20, 15),
      sourceCenter: const Offset(50, 27.5),
      sourceFontSize: 10,
    );
    expect(bounds.width, greaterThanOrEqualTo(20));
    expect(bounds.height, greaterThanOrEqualTo(15));
  });

  test('reserved bubble cell searches inside its own bounds near an OCR edge', () {
    Rect inside(Rect cell) => comicBubbleInnerBounds(
      polygons: const [[Offset(0, 0), Offset(100, 0), Offset(100, 100), Offset(0, 100)]],
      sourceBounds: const Rect.fromLTWH(-5.5, 38.5, 15, 23),
      sourceCenter: const Offset(2, 50), sourceFontSize: 22,
      layoutBounds: cell,
    );
    final bounds = inside(const Rect.fromLTWH(0, 0, 15, 100));
    expect(bounds.width, greaterThan(3));
    expect(bounds.height, greaterThan(23));
    expect(bounds.left, greaterThanOrEqualTo(0));
    expect(bounds.right, lessThanOrEqualTo(15));
    expect(inside(const Rect.fromLTWH(200, 200, 10, 10)), Rect.zero);
  });

  test('translation cache does not persist image-lifetime layout metadata',
      () async {
    final image = File('${temp.path}/stale-layout.bin');
    await image.writeAsBytes(List<int>.filled(263, 7));
    final identity = ComicTranslationPageIdentity(
      imageKey: image.uri.toString(),
      sourceKey: 'layout-cache',
      comicId: 'layout-cache',
      chapterId: '0',
      pageIndex: 0,
      mediaKind: ComicTranslationMediaKind.staticImage,
    );
    final ocr = _OcrEngine();
    final translator = _TranslationEngine();
    final registry = ComicTranslationEngineRegistry()
      ..ocrEngine = ocr
      ..translationEngine = translator;
    final first = ComicTranslationSession(
      enabled: true,
      sourceLanguage: 'ja',
      targetLanguage: 'zh-CN',
      engines: registry,
    );
    first.reportPages(
      current: [identity],
      interaction: ComicTranslationInteraction.idle,
    );
    final artifact = (await _waitFor(first, identity)).artifact!;
    first.dispose();
    final storedRegion =
        (artifact.toJson()['regions'] as List).single as Map<String, dynamic>;
    expect(storedRegion, isNot(contains('translationUnitId')));
    expect(storedRegion, isNot(contains('translationUnitOrder')));
    expect(storedRegion, isNot(contains('translationBandIndex')));
    expect(storedRegion, isNot(contains('translationOrientation')));

    final reopened = ComicTranslationSession(
      enabled: true,
      sourceLanguage: 'ja',
      targetLanguage: 'zh-CN',
      engines: registry,
    );
    reopened.reportPages(
      current: [identity],
      interaction: ComicTranslationInteraction.idle,
    );
    await _waitFor(reopened, identity);
    expect(translator.calls, 1);
    reopened.dispose();
  });

  test('engine leases keep shared models loaded until the final user leaves', () async {
    final ocr = _OcrEngine();
    final translator = _TranslationEngine();
    final registry = ComicTranslationEngineRegistry()
      ..ocrEngine = ocr
      ..translationEngine = translator;
    final first = await registry.acquire();
    final second = await registry.acquire();
    await registry.loadOcr(first, 'ja');
    await registry.loadTranslator(second);
    expect(ocr.loads, 1);
    expect(translator.loads, 1);
    await registry.release(first);
    expect(ocr.unloads, 0);
    expect(translator.unloads, 0);
    await registry.release(second);
    expect(ocr.unloads, 1);
    expect(translator.unloads, 1);
  });

  test('language recognizers share detection and do not reload for the same script group', () async {
    final ocr = _SwitchingOcrEngine();
    final registry = ComicTranslationEngineRegistry()..ocrEngine = ocr..translationEngine = _TranslationEngine();
    final pair = await registry.acquire();
    await registry.loadOcr(pair, 'ja');
    await registry.loadOcr(pair, 'en');
    await registry.loadOcr(pair, 'ko');
    expect(ocr.loads, 1);
    expect(ocr.switches, 1);
    expect(ocr.unloads, 0);
    await registry.release(pair);
    expect(ocr.unloads, 1);
  });

  testWidgets('idle model retention survives a comic language switch and expires', (tester) async {
    final ocr = _OcrEngine();
    final translator = _TranslationEngine();
    final registry = ComicTranslationEngineRegistry(idleRetention: const Duration(seconds: 30))
      ..ocrEngine = ocr..translationEngine = translator;
    final first = await registry.acquire();
    await registry.loadOcr(first, 'ja');
    await registry.loadTranslator(first);
    await registry.release(first);
    await tester.pump(const Duration(seconds: 20));
    expect(ocr.unloads, 0);
    expect(translator.unloads, 0);
    final korean = await registry.acquire();
    await registry.loadOcr(korean, 'ko');
    await registry.loadTranslator(korean);
    expect(ocr.loads, 2);
    expect(translator.loads, 1, reason: 'source-language changes share the translator weights');
    await registry.release(korean);
    await tester.pump(const Duration(seconds: 31));
    expect(ocr.unloads, 2);
    expect(translator.unloads, 1);
    await registry.trimMemory();
  });

  test('background trim waits for OCR exit and resumes from its stored result', () async {
    final image = File('${temp.path}/background-ocr.bin');
    await image.writeAsBytes(List<int>.filled(283, 29));
    final identity = ComicTranslationPageIdentity(imageKey: image.uri.toString(), sourceKey: 'background',
      comicId: 'comic', chapterId: 'chapter', pageIndex: 0, mediaKind: ComicTranslationMediaKind.staticImage);
    final started = Completer<void>();
    final gate = Completer<void>();
    final ocr = _OcrEngine(recognizeStarted: started, recognizeGate: gate);
    final translator = _TranslationEngine();
    final registry = ComicTranslationEngineRegistry()..ocrEngine = ocr..translationEngine = translator;
    final session = ComicTranslationSession(enabled: true, sourceLanguage: 'ja', targetLanguage: 'zh-CN', engines: registry);
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await session.close();
    });
    session.reportPages(current: [identity], interaction: ComicTranslationInteraction.idle);
    await started.future;
    var trimmed = false;
    final trimming = registry.setBackground(true).then((_) { trimmed = true; });
    await Future<void>.delayed(Duration.zero);
    expect(trimmed, isFalse);
    expect(ocr.unloads, 0);
    gate.complete();
    await trimming;
    expect(ocr.unloads, 1);
    expect(translator.calls, 0);
    await registry.setBackground(false);
    await _waitFor(session, identity);
    expect(ocr.calls, 1, reason: 'completed OCR remains cached across background cancellation');
    expect(translator.calls, 1);
  });

  test('automatic source language is learned once and applies to subsequent pages', () async {
    final pages = <ComicTranslationPageIdentity>[];
    for (var i = 0; i < 2; i++) {
      final image = File('${temp.path}/language-$i.bin');
      await image.writeAsBytes(List<int>.filled(291 + i, 37));
      pages.add(ComicTranslationPageIdentity(imageKey: image.uri.toString(), sourceKey: 'language',
        comicId: 'comic', chapterId: 'chapter', pageIndex: i, mediaKind: ComicTranslationMediaKind.staticImage));
    }
    final ocr = _OcrEngine(detectedSourceLanguage: 'ko');
    final registry = ComicTranslationEngineRegistry()..ocrEngine = ocr..translationEngine = _TranslationEngine();
    final learned = <String>[];
    final session = ComicTranslationSession(enabled: true, sourceLanguage: 'auto', targetLanguage: 'zh-CN',
      engines: registry, onSourceLanguageDetected: (language) async { learned.add(language); });
    addTearDown(session.close);
    session.reportPages(current: [pages.first], interaction: ComicTranslationInteraction.idle);
    await _waitFor(session, pages.first);
    session.reportPages(current: [pages.last], interaction: ComicTranslationInteraction.idle);
    await _waitFor(session, pages.last);
    expect(session.effectiveSourceLanguage, 'ko');
    expect(learned, ['ko']);
    expect(ocr.languages, ['auto', 'ko']);
  });

  test('blank OCR does not guess a source language or load a translator', () async {
    final image = File('${temp.path}/blank-language.bin');
    await image.writeAsBytes(List<int>.filled(311, 41));
    final identity = ComicTranslationPageIdentity(imageKey: image.uri.toString(), sourceKey: 'blank',
      comicId: 'comic', chapterId: 'chapter', pageIndex: 0, mediaKind: ComicTranslationMediaKind.staticImage);
    final translator = _TranslationEngine();
    final registry = ComicTranslationEngineRegistry()
      ..ocrEngine = _OcrEngine(regions: const [])..translationEngine = translator;
    final session = ComicTranslationSession(enabled: true, sourceLanguage: 'auto', targetLanguage: 'zh-CN', engines: registry);
    addTearDown(session.close);
    session.reportPages(current: [identity], interaction: ComicTranslationInteraction.idle);
    final state = await _waitFor(session, identity);
    expect(state.artifact!.regions, isEmpty);
    expect(session.effectiveSourceLanguage, 'auto');
    expect(translator.loads, 0);
    expect(translator.calls, 0);
  });

  test('engine generations switch without waiting for older leases', () async {
    final firstOcr = _OcrEngine(version: 'first');
    final firstTranslator = _TranslationEngine();
    final secondOcr = _OcrEngine(version: 'second');
    final secondTranslator = _TranslationEngine();
    final registry = ComicTranslationEngineRegistry()
      ..configure(
        ocrEngine: firstOcr,
        translationEngine: firstTranslator,
      );
    final first = await registry.acquire();
    await registry.loadOcr(first, 'ja');
    await registry.loadTranslator(first);

    registry.configure(
      ocrEngine: secondOcr,
      translationEngine: secondTranslator,
    );
    final second = await registry.acquire();
    expect(second.ocr, same(secondOcr));
    expect(second.translator, same(secondTranslator));
    await registry.loadOcr(second, 'ko');
    await registry.loadTranslator(second);
    expect(firstOcr.unloads, 1);
    expect(firstTranslator.unloads, 1);

    await registry.loadOcr(first, 'ja');
    await registry.loadTranslator(first);
    expect(secondOcr.unloads, 1);
    expect(secondTranslator.unloads, 1);
    await registry.release(second);
    await registry.loadOcr(first, 'ja');
    await registry.loadTranslator(first);
    expect(firstOcr.loads, 2);
    expect(firstTranslator.loads, 2);
    await registry.release(first);
    expect(firstOcr.unloads, 2);
    expect(firstTranslator.unloads, 2);
  });

  test('engine generations transfer unchanged loaded adapters', () async {
    final ocr = _OcrEngine();
    final firstTranslator = _TranslationEngine();
    final secondTranslator = _TranslationEngine();
    final registry = ComicTranslationEngineRegistry()
      ..configure(
        ocrEngine: ocr,
        translationEngine: firstTranslator,
      );
    final first = await registry.acquire();
    await registry.loadOcr(first, 'ja');
    registry.configure(
      ocrEngine: ocr,
      translationEngine: secondTranslator,
    );
    final second = await registry.acquire();
    await registry.loadOcr(second, 'ja');
    expect(ocr.loads, 1);
    expect(ocr.unloads, 0);
    await registry.release(second);
    expect(ocr.unloads, 0);
    await registry.loadOcr(first, 'ja');
    expect(ocr.loads, 1);
    await registry.release(first);
    expect(ocr.unloads, 1);
  });

  test('configured translator test does not require an OCR lease', () async {
    final translator = _TranslationEngine();
    final registry = ComicTranslationEngineRegistry()
      ..configure(ocrEngine: null, translationEngine: translator);
    final result = await registry.translateConfigured(ComicTranslationRequest(
      ocr: _ocrArtifact([_ocrRegion('test', 'Hello', 0, 1)]),
      targetLanguage: 'zh-CN',
      previousPages: const [],
    ));
    expect(result.translations.values.single, ['你好']);
    expect(translator.loads, 1);
    expect(translator.calls, 1);
    expect(translator.unloads, 1);
  });

  for (final retention in [Duration.zero, const Duration(seconds: 30)]) {
  test('release waits for queued recognition before retaining for $retention', () async {
    final started = Completer<void>();
    final gate = Completer<void>();
    final ocr = _OcrEngine(recognizeStarted: started, recognizeGate: gate);
    final registry = ComicTranslationEngineRegistry(idleRetention: retention)
      ..ocrEngine = ocr
      ..translationEngine = _TranslationEngine();
    final pair = await registry.acquire();
    const input = ComicOcrInput(
      identity: ComicTranslationPageIdentity(
        imageKey: 'registry-test',
        sourceKey: 'local',
        comicId: 'registry-test',
        chapterId: '0',
        pageIndex: 0,
        mediaKind: ComicTranslationMediaKind.staticImage,
      ),
      filePath: 'registry-test',
      contentDigest: 'registry-test',
      sourceLanguage: 'ja',
      maxAnalysisSide: 1600,
      animatedMode: AnimatedTranslationMode.posterFrame,
    );
    final first = registry.recognize(pair, 'ja', input);
    await started.future;
    final second = registry.recognize(pair, 'ja', input);
    final release = registry.release(pair);
    await Future<void>.delayed(Duration.zero);
    gate.complete();
    await Future.wait([first, second]);
    await release;
    expect(ocr.calls, 2);
    if (retention > Duration.zero) expect(ocr.unloads, 0);
    await registry.trimMemory();
    expect(ocr.unloads, 1);
  });
  }

  for (final cached in [true, false]) {
  test(cached ? 'a cached current page restores before another page finishes inference'
      : 'a cache-only miss never invokes a model beside running inference', () async {
    final pages = <ComicTranslationPageIdentity>[];
    for (var i = 0; i < 2; i++) {
      final image = File('${temp.path}/cache-lane-$cached-$i.bin');
      await image.writeAsBytes(List<int>.filled(377 + i, cached ? 47 : 53));
      pages.add(ComicTranslationPageIdentity(imageKey: image.uri.toString(), sourceKey: 'cache-lane',
        comicId: 'comic', chapterId: 'chapter', pageIndex: i, mediaKind: ComicTranslationMediaKind.staticImage));
    }
    final seedRegistry = ComicTranslationEngineRegistry()
      ..ocrEngine = _OcrEngine()..translationEngine = _TranslationEngine();
    final seed = ComicTranslationSession(enabled: true, sourceLanguage: 'ko', targetLanguage: 'zh-CN', engines: seedRegistry);
    seed.reportPages(current: [pages.first], interaction: ComicTranslationInteraction.idle);
    await _waitFor(seed, pages.first);
    await seed.close();

    final started = Completer<void>();
    final gate = Completer<void>();
    final ocr = _OcrEngine();
    final translator = _TranslationEngine(translateStarted: started, translateGate: gate);
    final registry = ComicTranslationEngineRegistry()..ocrEngine = ocr..translationEngine = translator;
    final events = <Map<String, Object?>>[];
    final probed = Completer<void>();
    final session = ComicTranslationSession(enabled: true, sourceLanguage: 'ko', targetLanguage: cached ? 'zh-CN' : 'en',
      engines: registry, onDiagnostic: (identity, details) {
        if (identity == pages.first) {
          events.add(details);
          if (details['stage'] == 'translation-cache' && details['cacheOnly'] == true && !probed.isCompleted) {
            probed.complete();
          }
        }
      });
    try {
      session.reportPages(current: [pages.last], interaction: ComicTranslationInteraction.idle);
      await started.future;
      session.reportPages(current: [pages.first], near: [pages.last], interaction: ComicTranslationInteraction.idle);
      await probed.future.timeout(const Duration(seconds: 2));
      if (cached) {
        final restored = await _waitFor(session, pages.first).timeout(const Duration(seconds: 2));
        expect(restored.artifact!.regions.single.translatedText, '你好');
      } else {
        expect(session.listenable(pages.first).value.artifact, isNull);
      }
      expect(gate.isCompleted, isFalse, reason: 'cache display cannot wait for model inference');
      expect(ocr.calls, 1);
      expect(translator.calls, 1);
      expect(events.where((event) => event['stage'] == 'translation-cache').single['hit'], cached);
      expect(events.where((event) => event['stage'] == 'translation-started'), isEmpty);
      gate.complete();
      await _waitFor(session, pages.first);
      await _waitFor(session, pages.last);
      await session.close();
      expect(ocr.calls, 1, reason: 'a cache-only miss must still reuse the completed OCR');
      expect(translator.calls, cached ? 1 : 2, reason: 'only a cache miss is submitted after the running model exits');
    } finally {
      if (!gate.isCompleted) gate.complete();
      await session.close();
    }
  });
  }

  test('translation survives a new session with different live context', () async {
    final firstImage = File('${temp.path}/context-page-0.bin');
    final secondImage = File('${temp.path}/context-page-1.bin');
    await firstImage.writeAsBytes(List<int>.filled(257, 1));
    await secondImage.writeAsBytes(List<int>.filled(259, 2));
    ComicTranslationPageIdentity identity(File file, int page) =>
        ComicTranslationPageIdentity(
          imageKey: file.uri.toString(),
          sourceKey: 'context-local',
          comicId: 'context-comic',
          chapterId: 'context-chapter',
          pageIndex: page,
          mediaKind: ComicTranslationMediaKind.staticImage,
        );
    final firstPage = identity(firstImage, 0);
    final secondPage = identity(secondImage, 1);
    final ocr = _OcrEngine();
    final translator = _TranslationEngine();
    final registry = ComicTranslationEngineRegistry()
      ..ocrEngine = ocr
      ..translationEngine = translator;
    final first = ComicTranslationSession(
      enabled: true,
      sourceLanguage: 'ja',
      targetLanguage: 'zh-CN',
      engines: registry,
    );
    first.reportPages(
      current: [firstPage],
      interaction: ComicTranslationInteraction.idle,
    );
    await _waitFor(first, firstPage);
    first.reportPages(
      current: [secondPage],
      interaction: ComicTranslationInteraction.idle,
    );
    await _waitFor(first, secondPage);
    expect(translator.calls, 2);
    first.dispose();

    final reopened = ComicTranslationSession(
      enabled: true,
      sourceLanguage: 'ja',
      targetLanguage: 'zh-CN',
      engines: registry,
    );
    reopened.reportPages(
      current: [secondPage],
      interaction: ComicTranslationInteraction.idle,
    );
    await _waitFor(reopened, secondPage);
    expect(translator.calls, 2);
    reopened.dispose();
  });

  test('context-free translator ignores prior pages in requests and cache', () async {
    final firstImage = File('${temp.path}/local-context-0.bin');
    final secondImage = File('${temp.path}/local-context-1.bin');
    await firstImage.writeAsBytes(List<int>.filled(267, 1));
    await secondImage.writeAsBytes(List<int>.filled(269, 2));
    ComicTranslationPageIdentity identity(File file, int page) =>
        ComicTranslationPageIdentity(
          imageKey: file.uri.toString(),
          sourceKey: 'local-context',
          comicId: 'local-context',
          chapterId: 'chapter',
          pageIndex: page,
          mediaKind: ComicTranslationMediaKind.staticImage,
        );
    final firstPage = identity(firstImage, 0);
    final secondPage = identity(secondImage, 1);
    final translator = _TranslationEngine(
      contextMode: ComicTranslationContextMode.none,
    );
    final registry = ComicTranslationEngineRegistry()
      ..ocrEngine = _OcrEngine()
      ..translationEngine = translator;
    final session = ComicTranslationSession(
      enabled: true,
      sourceLanguage: 'ja',
      targetLanguage: 'zh-CN',
      engines: registry,
    );
    session.reportPages(
      current: [firstPage],
      interaction: ComicTranslationInteraction.idle,
    );
    await _waitFor(session, firstPage);
    session.reportPages(
      current: [secondPage],
      interaction: ComicTranslationInteraction.idle,
    );
    await _waitFor(session, secondPage);
    expect(translator.lastRequest!.previousPages, isEmpty);
    expect(translator.calls, 2);
    session.dispose();

    final reopened = ComicTranslationSession(
      enabled: true,
      sourceLanguage: 'ja',
      targetLanguage: 'zh-CN',
      engines: registry,
    );
    reopened.reportPages(
      current: [secondPage],
      interaction: ComicTranslationInteraction.idle,
    );
    await _waitFor(reopened, secondPage);
    expect(translator.calls, 2);
    reopened.dispose();
  });

  test('additional remote prompt participates in translation cache identity', () {
    final request = ComicTranslationRequest(
      ocr: _ocrArtifact([_ocrRegion('test', 'Hello', 0, 1)]),
      targetLanguage: 'zh-CN',
      previousPages: const [],
    );
    OpenAiCompatibleComicTranslationEngine engine(String prompt) =>
        OpenAiCompatibleComicTranslationEngine(
          endpoint: 'https://example.com/v1/chat/completions',
          model: 'test',
          apiKey: '',
          additionalPrompt: prompt,
        );
    String version(String prompt) => engine(prompt).identityFor(request).modelVersion;
    expect(version(' names '), version('names'));
    expect(version('formal'), isNot(version('casual')));
  });

  testWidgets('remote retry preserves successful batches and only repeats a failed batch', (tester) async {
    final request = ComicTranslationRequest(ocr: _ocrArtifact([]), targetLanguage: 'zh-CN',
      previousPages: const [], units: [for (var index = 0; index < 17; index++)
        ComicTranslationUnit(id: 'r$index', regionIds: ['r$index'], sourceLines: ['$index'],
          orientation: ComicTextOrientation.horizontal, bandRegionIds: [['r$index']])]);
    final calls = <String, int>{};
    final adapter = _DeepLAdapter.generated((options) {
      final messages = (options.data as Map)['messages'] as List;
      final units = (jsonDecode((messages.last as Map)['content'] as String) as Map)['units'] as List;
      final first = ((units.first as Map)['sourceLines'] as List).single as String;
      calls[first] = (calls[first] ?? 0) + 1;
      if (first == '16' && calls[first]! < 3) throw DioException(requestOptions: options,
        error: const HandshakeException('Connection terminated during handshake'));
      return {'translations': {for (final unit in units)
        (unit as Map)['id']: ['译文${(unit['sourceLines'] as List).single}']}};
    });
    final previousAdapter = ComicTranslationHttp.adapterFactory;
    ComicTranslationHttp.adapterFactory = () => adapter;
    addTearDown(() => ComicTranslationHttp.adapterFactory = previousAdapter);
    final engine = OpenAiCompatibleComicTranslationEngine(
      endpoint: 'https://example.com/v1/chat/completions', model: 'test', apiKey: '');
    final work = engine.translate(request);
    Future<void> flushHttp() async {
      for (var index = 0; index < 4; index++) await tester.pump(Duration.zero);
    }
    await flushHttp();
    expect(calls, {'0': 1, '16': 1});
    await tester.pump(const Duration(seconds: 2));
    await flushHttp();
    expect(calls, {'0': 1, '16': 2});
    await tester.pump(const Duration(seconds: 5));
    await flushHttp();
    expect((await work).translations, {for (var index = 0; index < 17; index++)
      'r$index': ['译文$index']});
    expect(calls, {'0': 1, '16': 3});
  });

  for (final repair in [false, true]) {
  test(repair ? 'remote translation repairs only empty units once'
      : 'valid remote translation never needs an extra request', () async {
    final request = ComicTranslationRequest(
      ocr: _ocrArtifact([
        _ocrRegion('good', 'ありがとう', 0, 0, left: .7),
        _ocrRegion('empty', 'ごめん', 1, 1),
      ]),
      targetLanguage: 'zh-CN', previousPages: const [],
    );
    expect(request.units, hasLength(2));
    var calls = 0;
    final adapter = _DeepLAdapter.generated((options) {
      calls++;
      return {'translations': calls == 1
          ? {'u0': ['谢谢'], 'u1': repair ? <String>[] : ['抱歉']}
          : {'u0': ['抱歉']}};
    });
    final previousAdapter = ComicTranslationHttp.adapterFactory;
    ComicTranslationHttp.adapterFactory = () => adapter;
    addTearDown(() => ComicTranslationHttp.adapterFactory = previousAdapter);
    final engine = OpenAiCompatibleComicTranslationEngine(
      endpoint: 'https://example.com/v1/chat/completions', model: 'test', apiKey: '',
    );
    final result = await engine.translate(request);
    expect(result.translations, {
      request.units[0].id: ['谢谢'], request.units[1].id: ['抱歉'],
    });
    expect(adapter.requests, hasLength(repair ? 2 : 1));
    final messages = (adapter.requests.last.data as Map)['messages'] as List;
    final body = jsonDecode((messages.last as Map)['content'] as String) as Map;
    expect(body['units'], repair
        ? [{'id': 'u0', 'sourceLines': request.units[1].sourceLines}]
        : [for (var i = 0; i < request.units.length; i++)
            {'id': 'u$i', 'sourceLines': request.units[i].sourceLines}]);
    if (repair) expect((messages.first as Map)['content'], contains('nonempty'));
  });
  }

  for (final cancelAt in [0, 1, 2]) {
    test('remote empty-unit repair stays bounded with cancellation at $cancelAt', () async {
      final request = ComicTranslationRequest(
        ocr: _ocrArtifact([_ocrRegion('empty', 'ごめん', 0, 0)]),
        targetLanguage: 'zh-CN', previousPages: const [],
      );
      var calls = 0;
      final adapter = _DeepLAdapter.generated((options) {
        calls++;
        if (calls == cancelAt) {
          throw DioException(requestOptions: options, type: DioExceptionType.cancel);
        }
        return {'translations': {'u0': [' ']}};
      });
      final previousAdapter = ComicTranslationHttp.adapterFactory;
      ComicTranslationHttp.adapterFactory = () => adapter;
      addTearDown(() => ComicTranslationHttp.adapterFactory = previousAdapter);
      final engine = OpenAiCompatibleComicTranslationEngine(
        endpoint: 'https://example.com/v1/chat/completions', model: 'test', apiKey: '',
      );
      await expectLater(engine.translate(request), cancelAt == 0
          ? throwsFormatException : throwsA(isA<DioException>().having(
              (error) => error.type, 'type', DioExceptionType.cancel)));
      expect(adapter.requests, hasLength(cancelAt == 1 ? 1 : 2));
    });
  }

  test('DeepL profile backend survives persistence and old profiles migrate', () {
    const profile = ComicTranslationRemoteProfile(
      id: 'deepl',
      backend: 'deepl',
      name: 'DeepL Free',
      endpoint: 'https://api-free.deepl.com/v2/translate',
      model: 'latency_optimized',
      additionalPrompt: '',
    );
    expect(ComicTranslationRemoteProfile.fromJson(profile.toJson()).backend,
        'deepl');
    final legacy = Map<String, dynamic>.from(profile.toJson())
      ..remove('backend');
    expect(ComicTranslationRemoteProfile.fromJson(legacy).backend,
        'openaiCompatible');
  });

  test('DeepL maps ordered translations without sending unit ids', () async {
    final request = ComicTranslationRequest(
      ocr: _ocrArtifact([
        _positionedRegion('a0', '好き', 0.62, 0.1, 0.08, 0.18, 0,
            bubbleGroupId: 1),
        _positionedRegion('a1', 'です', 0.52, 0.1, 0.08, 0.18, 1,
            bubbleGroupId: 1),
        _positionedRegion('b0', '次へ', 0.25, 0.6, 0.08, 0.18, 2,
            bubbleGroupId: 2),
      ]),
      targetLanguage: 'zh-CN',
      previousPages: const [],
    );
    expect(request.units, hasLength(2));
    final adapter = _DeepLAdapter({
      'translations': const [
        {'text': '非常\n喜欢'},
        {'text': '下一页'},
      ],
    });
    final client = Dio()..httpClientAdapter = adapter;
    final engine = DeepLComicTranslationEngine(
      endpoint: 'https://api-free.deepl.com/v2/translate',
      modelType: 'latency_optimized',
      apiKey: 'secret',
      client: client,
    );
    final result = await engine.translate(request);
    final body = adapter.request!.data as Map<String, dynamic>;
    expect(body['text'], request.units
        .map((unit) => unit.sourceLines.join('\n')).toList());
    expect(jsonEncode(body), isNot(contains(request.units.first.id)));
    expect(result.translations[request.units[0].id], ['非常', '喜欢']);
    expect(result.translations[request.units[1].id], ['下一页']);
    expect(
      adapter.request!.headers['Authorization'],
      'DeepL-Auth-Key secret',
    );
  });

  test('DeepL blank model type uses the explicit default for request and identity', () async {
    final request = ComicTranslationRequest(
      ocr: _ocrArtifact([_ocrRegion('test', 'Hello', 0, 1)]),
      targetLanguage: 'zh-CN',
      previousPages: const [],
    );
    final adapter = _DeepLAdapter({'translations': const [{'text': '你好'}]});
    final engine = DeepLComicTranslationEngine(
      endpoint: 'https://api-free.deepl.com/v2/translate',
      modelType: ' \n\t ',
      apiKey: 'secret',
      client: Dio()..httpClientAdapter = adapter,
    );
    final defaultEngine = DeepLComicTranslationEngine(
      endpoint: engine.endpoint,
      apiKey: 'secret',
    );
    expect(engine.identityFor(request).modelVersion,
        defaultEngine.identityFor(request).modelVersion);
    final result = await engine.translate(request);
    expect((adapter.request!.data as Map)['model_type'], 'latency_optimized');
    expect(result.translations[request.units.single.id], ['你好']);
  });

  test('DeepL rejects unknown model types instead of changing semantics', () {
    final engine = DeepLComicTranslationEngine(
      endpoint: 'https://api-free.deepl.com/v2/translate',
      modelType: 'fast-ish',
      apiKey: 'secret',
    );
    final request = ComicTranslationRequest(
      ocr: _ocrArtifact([_ocrRegion('test', 'Hello', 0, 1)]),
      targetLanguage: 'zh-CN',
      previousPages: const [],
    );
    expect(() => engine.identityFor(request), throwsStateError);
  });

  test('DeepL propagates cancellation without submitting another request', () async {
    final adapter = _DeepLAdapter.generated((options) {
      throw DioException(requestOptions: options, type: DioExceptionType.cancel);
    });
    final client = Dio()..httpClientAdapter = adapter;
    addTearDown(() => client.close(force: true));
    final engine = DeepLComicTranslationEngine(
      endpoint: 'https://api-free.deepl.com/v2/translate',
      apiKey: 'test', client: client,
    );
    final request = ComicTranslationRequest(
      ocr: _ocrArtifact([_ocrRegion('test', 'Hello', 0, 1)]),
      targetLanguage: 'zh-CN', previousPages: const [],
    );
    await expectLater(engine.translate(request), throwsA(isA<DioException>().having(
      (error) => error.type, 'type', DioExceptionType.cancel)));
    expect(adapter.requests, hasLength(1));
  });

  test('DeepL batches at 50 ordered texts', () async {
    final request = ComicTranslationRequest(
      ocr: _ocrArtifact(List.generate(51, (index) => _positionedRegion(
        'r$index',
        '原$index',
        0.1,
        0.1,
        0.08,
        0.18,
        index,
        bubbleGroupId: index,
      ))),
      targetLanguage: 'zh-CN',
      previousPages: const [],
    );
    expect(request.units, hasLength(51));
    final adapter = _DeepLAdapter.generated((options) {
      final texts = (options.data as Map<String, dynamic>)['text'] as List;
      return {
        'translations': List.generate(
          texts.length,
          (index) => {'text': '译$index'},
        ),
      };
    });
    final engine = DeepLComicTranslationEngine(
      endpoint: 'https://api-free.deepl.com/v2/translate',
      apiKey: 'secret',
      client: Dio()..httpClientAdapter = adapter,
    );
    final result = await engine.translate(request);
    expect(adapter.requests.map((request) =>
        ((request.data as Map<String, dynamic>)['text'] as List).length),
        [50, 1]);
    expect(result.translations, hasLength(51));
  });

  test('remote translation JSON tolerates wrapper text and braces in strings', () {
    final value = decodeComicTranslationJson(
      'result follows:\n```json\n'
      '{"translations":{"bubble:1":["保留 {括号}"]}}\n```\ndone',
    );
    expect(value['translations'], {'bubble:1': ['保留 {括号}']});
  });

  test('open Japanese OCR regions cluster and sort by positional columns', () {
    final artifact = _ocrArtifact([
      _positionedRegion('left', '左', 0.42, 0.12, 0.08, 0.42, 0),
      _positionedRegion('right-bottom', '下', 0.55, 0.34, 0.08, 0.2, 1),
      _positionedRegion('right-top', '上', 0.55, 0.1, 0.08, 0.2, 2),
    ]);
    final units = ComicTranslationUnit.fromOcr(artifact);
    expect(units, hasLength(1));
    expect(units.single.regionIds, ['right-top', 'right-bottom', 'left']);
    expect(units.single.sourceLines, ['上', '下', '左']);
  });

  test('different bubble groups remain separate despite close positions', () {
    final artifact = _ocrArtifact([
      _positionedRegion('a', '甲', 0.55, 0.1, 0.08, 0.3, 0,
          bubbleGroupId: 1),
      _positionedRegion('b', '乙', 0.45, 0.1, 0.08, 0.3, 1,
          bubbleGroupId: 2),
    ]);
    expect(ComicTranslationUnit.fromOcr(artifact), hasLength(2));
  });

  test('Korean stacked lines can cross unreliable native bubble groups', () {
    final artifact = _ocrArtifact([
      _positionedRegion('r0', '태어나지도', .2, .10, .5, .08, 0,
          bubbleGroupId: 0, orientation: ComicTextOrientation.horizontal),
      _positionedRegion('r1', '못한 아이를', .2, .19, .5, .08, 1,
          bubbleGroupId: 0, orientation: ComicTextOrientation.horizontal),
      _positionedRegion('r2', '둘이나 어깨위에', .2, .28, .5, .08, 2,
          bubbleGroupId: 1, orientation: ComicTextOrientation.horizontal),
      _positionedRegion('r3', '태운주제에', .2, .37, .5, .08, 3,
          orientation: ComicTextOrientation.horizontal,
          backgroundArgb: 0xff777777),
    ], sourceLanguage: 'ko');
    final units = ComicTranslationUnit.fromOcr(artifact);
    expect(units, hasLength(1));
    expect(units.single.regionIds, ['r0', 'r1', 'r2', 'r3']);

    final regions = artifact.regions.map((region) => ComicTextRegion(
      value: region,
      id: region.id,
      text: region.text,
      polygon: region.polygon,
      sourceMaskPolygons: region.sourceMaskPolygons,
      orientation: region.orientation,
      backgroundArgb: region.backgroundArgb,
      bubbleGroupId: region.bubbleGroupId,
      bubblePolygon: region.bubblePolygon,
    )).toList();
    final unitIds = {for (final id in units.single.regionIds) id: units.single.id};
    final grouping = ComicTextGrouping(
      imageWidth: artifact.imageWidth,
      imageHeight: artifact.imageHeight,
      sourceLanguage: artifact.sourceLanguage,
    );
    expect(grouping.diagnoseRelations(
      regions,
      unitIds,
      relatedFilter: true,
      regionIndices: const {1, 2},
    ).single, contains('related=true'));
    expect(grouping.diagnoseRelations(
      regions,
      unitIds,
      relatedFilter: false,
      regionIndices: const {1, 2},
    ), isEmpty);
    expect(grouping.diagnoseRelations(
      regions,
      unitIds,
      regionIndices: const {1},
    ), hasLength(3));
  });

  test('distant single glyph does not join dialogue by endpoint contact', () {
    const bubble = [
      NormalizedPoint(.18, .70), NormalizedPoint(.32, .70),
      NormalizedPoint(.32, .83), NormalizedPoint(.18, .83),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion('edge', 'は', .269, .733, .037, .059, 0,
          bubbleGroupId: 6, bubblePolygon: bubble),
      _positionedRegion('body', '明日', .230, .772, .030, .032, 1,
          bubbleGroupId: 6, bubblePolygon: bubble),
    ]);
    expect(ComicTranslationUnit.fromOcr(artifact), hasLength(2));
  });

  test('oversized single OCR mark stays outside nearby body columns', () {
    const bubble = [
      NormalizedPoint(.18, .48), NormalizedPoint(.32, .48),
      NormalizedPoint(.32, .62), NormalizedPoint(.18, .62),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion('body-1', 'あんたでしょ', .255, .502, .027, .087, 0,
          bubbleGroupId: 4, bubblePolygon: bubble),
      _positionedRegion('body-2', 'やめなかったの', .276, .502, .031, .098, 1,
          bubbleGroupId: 4, bubblePolygon: bubble),
      _positionedRegion('mark', '北', .209, .548, .041, .041, 2,
          bubbleGroupId: 4, bubblePolygon: bubble),
    ]);
    final units = ComicTranslationUnit.fromOcr(artifact);
    expect(units, hasLength(2));
    expect(units.singleWhere((unit) => unit.regionIds.length == 2).regionIds,
        ['body-2', 'body-1']);
  });

  test('staggered columns without rectangular contact stay separate', () {
    final artifact = _ocrArtifact([
      _positionedRegion('right', '右列', 0.58, 0.08, 0.08, 0.22, 0,
          bubbleGroupId: 7),
      _positionedRegion('left', '左列', 0.34, 0.64, 0.08, 0.22, 1,
          bubbleGroupId: 7),
    ]);
    final units = ComicTranslationUnit.fromOcr(artifact);
    expect(units, hasLength(2));
  });

  test('connected bubble lobes separated on the reading axis stay separate', () {
    const bubble = [
      NormalizedPoint(0.44, 0.04),
      NormalizedPoint(0.72, 0.04),
      NormalizedPoint(0.72, 0.28),
      NormalizedPoint(0.58, 0.28),
      NormalizedPoint(0.58, 0.49),
      NormalizedPoint(0.3, 0.49),
      NormalizedPoint(0.3, 0.25),
      NormalizedPoint(0.44, 0.25),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion('upper-right', '上右', 0.58, 0.08, 0.08, 0.18, 0,
          bubbleGroupId: 7, bubblePolygon: bubble),
      _positionedRegion('upper-left', '上左', 0.48, 0.1, 0.08, 0.18, 1,
          bubbleGroupId: 7, bubblePolygon: bubble),
      _positionedRegion('lower-right', '下右', 0.5, 0.27, 0.08, 0.18, 2,
          bubbleGroupId: 7, bubblePolygon: bubble),
      _positionedRegion('lower-left', '下左', 0.4, 0.29, 0.08, 0.18, 3,
          bubbleGroupId: 7, bubblePolygon: bubble),
    ]);
    final units = ComicTranslationUnit.fromOcr(artifact);
    expect(units, hasLength(2));
    expect(units.map((unit) => unit.regionIds.toSet().join(',')).toSet(), {
      'upper-right,upper-left',
      'lower-right,lower-left',
    });
  });

  test('concave bubble keeps close high-overlap text together', () {
    const bubble = [
      NormalizedPoint(0.44, 0.04),
      NormalizedPoint(0.72, 0.04),
      NormalizedPoint(0.72, 0.28),
      NormalizedPoint(0.58, 0.28),
      NormalizedPoint(0.58, 0.49),
      NormalizedPoint(0.3, 0.49),
      NormalizedPoint(0.3, 0.25),
      NormalizedPoint(0.44, 0.25),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'long', '好きなの', 0.54, 0.08, 0.07, 0.28, 0,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
      _positionedRegion(
        'overlap', 'いいわよ', 0.555, 0.17, 0.07, 0.28, 1,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
    ]);
    expect(ComicTranslationUnit.fromOcr(artifact), hasLength(1));
  });

  test('centered short column remains with a longer column', () {
    const bubble = [
      NormalizedPoint(0.3, 0.04),
      NormalizedPoint(0.72, 0.04),
      NormalizedPoint(0.72, 0.76),
      NormalizedPoint(0.3, 0.76),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'long', '这是一个比较长的句子', 0.56, 0.08, 0.08, 0.5, 0,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
      _positionedRegion(
        'short', '短句', 0.46, 0.28, 0.08, 0.1, 1,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
    ]);
    final units = ComicTranslationUnit.fromOcr(artifact);
    expect(units, hasLength(1));
    expect(units.single.regionIds, ['long', 'short']);
  });

  test('overlapping columns have no gap between same and adjacent bands', () {
    const bubble = [
      NormalizedPoint(0.78, 0.36),
      NormalizedPoint(0.9, 0.36),
      NormalizedPoint(0.9, 0.54),
      NormalizedPoint(0.78, 0.54),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'r9', 'さーてと', 0.839, 0.415, 0.026, 0.068, 0,
        bubbleGroupId: 3,
        bubblePolygon: bubble,
      ),
      _positionedRegion(
        'r11', 'お風呂', 0.8245, 0.424, 0.026, 0.0504, 1,
        bubbleGroupId: 3,
        bubblePolygon: bubble,
      ),
    ]);
    final unit = ComicTranslationUnit.fromOcr(artifact).single;
    expect(unit.bandRegionIds, hasLength(2));
  });

  test('main-axis mask bias does not split three staggered body regions', () {
    const bubble = [
      NormalizedPoint(0.3, 0.05),
      NormalizedPoint(0.72, 0.05),
      NormalizedPoint(0.72, 0.88),
      NormalizedPoint(0.3, 0.88),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'r9', 'さーてと', 0.6, 0.12, 0.06, 0.22, 0,
        bubbleGroupId: 3,
        bubblePolygon: bubble,
        sourceMaskPolygons: const [[
          NormalizedPoint(0.6, 0.12), NormalizedPoint(0.66, 0.12),
          NormalizedPoint(0.66, 0.34), NormalizedPoint(0.6, 0.34),
        ]],
      ),
      _positionedRegion(
        'r10', 'お風呂', 0.5, 0.24, 0.06, 0.22, 1,
        bubbleGroupId: 3,
        bubblePolygon: bubble,
        sourceMaskPolygons: const [[
          NormalizedPoint(0.5, 0.24), NormalizedPoint(0.56, 0.24),
          NormalizedPoint(0.56, 0.46), NormalizedPoint(0.5, 0.46),
        ]],
      ),
      _positionedRegion(
        'r11', '入りましょうか', 0.4, 0.34, 0.06, 0.34, 2,
        bubbleGroupId: 3,
        bubblePolygon: bubble,
        sourceMaskPolygons: const [[
          NormalizedPoint(0.4, 0.55), NormalizedPoint(0.46, 0.55),
          NormalizedPoint(0.46, 0.68), NormalizedPoint(0.4, 0.68),
        ]],
      ),
    ]);
    final unit = ComicTranslationUnit.fromOcr(artifact).single;
    expect(unit.orientation, ComicTextOrientation.vertical);
    expect(unit.bandRegionIds, hasLength(3));
  });

  test('main-axis mask bias does not split two overlapping body columns', () {
    const bubble = [
      NormalizedPoint(0.32, 0.08),
      NormalizedPoint(0.72, 0.08),
      NormalizedPoint(0.72, 0.88),
      NormalizedPoint(0.32, 0.88),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'r16', '日焼け止め', 0.58, 0.22, 0.06, 0.35, 0,
        bubbleGroupId: 2,
        bubblePolygon: bubble,
        sourceMaskPolygons: const [[
          NormalizedPoint(0.58, 0.22), NormalizedPoint(0.64, 0.22),
          NormalizedPoint(0.64, 0.57), NormalizedPoint(0.58, 0.57),
        ]],
      ),
      _positionedRegion(
        'r17', '見ていい？', 0.46, 0.4, 0.06, 0.32, 1,
        bubbleGroupId: 2,
        bubblePolygon: bubble,
        sourceMaskPolygons: const [[
          NormalizedPoint(0.46, 0.58), NormalizedPoint(0.52, 0.58),
          NormalizedPoint(0.52, 0.72), NormalizedPoint(0.46, 0.72),
        ]],
      ),
    ]);
    final unit = ComicTranslationUnit.fromOcr(artifact).single;
    expect(unit.orientation, ComicTextOrientation.vertical);
    expect(unit.bandRegionIds, hasLength(2));
  });

  test('resolved native bubble is not split into an extra text group', () {
    const upperLobe = [
      NormalizedPoint(0.42, 0.04),
      NormalizedPoint(0.7, 0.04),
      NormalizedPoint(0.7, 0.42),
      NormalizedPoint(0.42, 0.42),
    ];
    const lowerLobe = [
      NormalizedPoint(0.3, 0.48),
      NormalizedPoint(0.58, 0.48),
      NormalizedPoint(0.58, 0.86),
      NormalizedPoint(0.3, 0.86),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'upper-long', '较长的句子', 0.55, 0.07, 0.07, 0.2, 0,
        bubbleGroupId: 7,
        bubblePolygon: upperLobe,
      ),
      _positionedRegion(
        'upper-short', '短句', 0.55, 0.31, 0.07, 0.07, 1,
        bubbleGroupId: 7,
        bubblePolygon: upperLobe,
      ),
      _positionedRegion(
        'lower', '另一个气泡', 0.43, 0.56, 0.07, 0.2, 2,
        bubbleGroupId: 8,
        bubblePolygon: lowerLobe,
      ),
    ]);
    final units = ComicTranslationUnit.fromOcr(artifact);
    expect(units, hasLength(2));
    expect(units.first.regionIds, ['upper-long', 'upper-short']);
  });

  test('distant text on one bubble outline is not forced into its group', () {
    const bubble = [
      NormalizedPoint(0.3, 0.04),
      NormalizedPoint(0.72, 0.04),
      NormalizedPoint(0.72, 0.9),
      NormalizedPoint(0.3, 0.9),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'dialogue', '气泡正文', 0.54, 0.08, 0.07, 0.18, 0,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
      _positionedRegion(
        'outline-noise', '边缘文字', 0.54, 0.72, 0.07, 0.1, 1,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
    ]);
    expect(ComicTranslationUnit.fromOcr(artifact), hasLength(2));
  });

  test('single-character endpoint contact joins the neighboring column', () {
    const bubble = [
      NormalizedPoint(0.34, 0.16),
      NormalizedPoint(0.64, 0.16),
      NormalizedPoint(0.64, 0.82),
      NormalizedPoint(0.34, 0.82),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'prefix', '前', 0.5, 0.28, 0.16, 0.07, 0,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
        orientation: ComicTextOrientation.horizontal,
        sourceMaskPolygons: const [[
          NormalizedPoint(0.5, 0.28),
          NormalizedPoint(0.57, 0.28),
          NormalizedPoint(0.57, 0.35),
          NormalizedPoint(0.5, 0.35),
        ]],
      ),
      _positionedRegion(
        'body', '映画の広告', 0.43, 0.35, 0.07, 0.35, 1,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
    ]);
    final unit = ComicTranslationUnit.fromOcr(artifact).single;
    expect(unit.orientation, ComicTextOrientation.vertical);
  });

  test('unit orientation ignores whitespace in wide OCR body boxes', () {
    const bubble = [
      NormalizedPoint(0.34, 0.16), NormalizedPoint(0.68, 0.16),
      NormalizedPoint(0.68, 0.82), NormalizedPoint(0.34, 0.82),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'prefix', '前', .5, .28, .16, .07, 0,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
        orientation: ComicTextOrientation.horizontal,
        sourceMaskPolygons: const [[
          NormalizedPoint(.5, .28), NormalizedPoint(.57, .28),
          NormalizedPoint(.57, .35), NormalizedPoint(.5, .35),
        ]],
      ),
      _positionedRegion(
        'body', '映画の広告', .4, .35, .2, .15, 1,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
        orientation: ComicTextOrientation.horizontal,
        sourceMaskPolygons: const [[
          NormalizedPoint(.43, .35), NormalizedPoint(.5, .35),
          NormalizedPoint(.5, .7), NormalizedPoint(.43, .7),
        ]],
      ),
    ]);
    final unit = ComicTranslationUnit.fromOcr(artifact).single;
    expect(unit.orientation, ComicTextOrientation.vertical);
  });

  test('ambiguous single character follows neighboring vertical text', () {
    final artifact = _ocrArtifact([
      _positionedRegion(
        'prefix', '前', 0.52, 0.28, 0.07, 0.07, 0,
        orientation: ComicTextOrientation.horizontal,
      ),
      _positionedRegion(
        'body', '映画の広告', 0.43, 0.35, 0.07, 0.35, 1,
      ),
    ]);
    expect(ComicTranslationUnit.fromOcr(artifact), hasLength(1));
  });

  test('parallel columns survive OCR box overlap when centers stay distinct', () {
    const bubble = [
      NormalizedPoint(0.38, 0.12),
      NormalizedPoint(0.72, 0.12),
      NormalizedPoint(0.72, 0.86),
      NormalizedPoint(0.38, 0.86),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'right', '……なんで', 0.55, 0.25, 0.1, 0.4, 0,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
      _positionedRegion(
        'left', '一緒なの', 0.475, 0.42, 0.1, 0.28, 1,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
    ]);
    final unit = ComicTranslationUnit.fromOcr(artifact).single;
    expect(unit.bandRegionIds, hasLength(2));
  });

  test('partly outside bubble text does not join by short-span overlap', () {
    const bubble = [
      NormalizedPoint(0.32, 0.08),
      NormalizedPoint(0.72, 0.08),
      NormalizedPoint(0.72, 0.88),
      NormalizedPoint(0.32, 0.88),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'body', '明日昼置き確定', 0.45, 0.25, 0.12, 0.45, 0,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
      _positionedRegion(
        'edge', 'はぁ…', 0.68, 0.12, 0.12, 0.25, 1,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
    ]);
    expect(ComicTranslationUnit.fromOcr(artifact), hasLength(2));
  });

  test('large annotation stays separate from body in one OCR bubble', () {
    const bubble = [
      NormalizedPoint(0.3, 0.08),
      NormalizedPoint(0.72, 0.08),
      NormalizedPoint(0.72, 0.88),
      NormalizedPoint(0.3, 0.88),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'body', '明日昼置き確定', 0.48, 0.3, 0.06, 0.42, 0,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
      _positionedRegion(
        'annotation', 'はぁ…', 0.59, 0.12, 0.1, 0.24, 1,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
    ]);
    expect(ComicTranslationUnit.fromOcr(artifact), hasLength(2));
  });

  test('distant oversized single mark stays outside the dialogue group', () {
    const bubble = [
      NormalizedPoint(0.3, 0.08),
      NormalizedPoint(0.72, 0.08),
      NormalizedPoint(0.72, 0.88),
      NormalizedPoint(0.3, 0.88),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'body', 'やめなかったの', 0.48, 0.18, 0.06, 0.52, 0,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
      _positionedRegion(
        'mark', '北', 0.12, 0.4, 0.25, 0.18, 1,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
        sourceMaskPolygons: const [[
          NormalizedPoint(0.2, 0.43),
          NormalizedPoint(0.32, 0.43),
          NormalizedPoint(0.32, 0.55),
          NormalizedPoint(0.2, 0.55),
        ]],
      ),
    ]);
    expect(ComicTranslationUnit.fromOcr(artifact), hasLength(2));
  });

  test('cross distance is smooth at 1.9 chars and penalizes farther text', () {
    const bubble = [
      NormalizedPoint(0.2, 0.08),
      NormalizedPoint(0.75, 0.08),
      NormalizedPoint(0.75, 0.82),
      NormalizedPoint(0.2, 0.82),
    ];
    ComicOcrArtifact artifact(double distance) => _ocrArtifact([
      _positionedRegion(
        'right', '右側の本文だ', 0.55, 0.2, 0.05, 0.3, 0,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
      _positionedRegion(
        'left', '左側の本文だ', 0.55 - distance * 0.05,
        0.2, 0.05, 0.3, 1,
        bubbleGroupId: 7,
        bubblePolygon: bubble,
      ),
    ]);
    expect(ComicTranslationUnit.fromOcr(artifact(1.89)), hasLength(1));
    expect(ComicTranslationUnit.fromOcr(artifact(1.91)), hasLength(1));
    expect(ComicTranslationUnit.fromOcr(artifact(2.4)), hasLength(2));
  });

  test('punctuation-only groups are not submitted for translation', () {
    final artifact = _ocrArtifact([
      _positionedRegion('noise', '……?!', 0.5, 0.2, 0.08, 0.2, 0),
      _positionedRegion('fragment', '……ら', 0.2, 0.7, 0.08, 0.2, 1),
    ]);
    expect(ComicTranslationUnit.fromOcr(artifact), isEmpty);
  });

  test('short dialogue inside a detected bubble is not discarded as noise', () {
    final artifact = _ocrArtifact([
      _positionedRegion(
        'short', '……ら', 0.5, 0.2, 0.08, 0.2, 0,
        bubbleGroupId: 7,
      ),
    ]);
    expect(ComicTranslationUnit.fromOcr(artifact).single.sourceLines, ['……ら']);
  });

  test('bubble body font uses line advance when glyph ink is narrow', () {
    final outside = comicTextFontSize(
      crossExtent: 4,
      mainExtent: 40,
      characters: 4,
      bodyContext: false,
    );
    final body = comicTextFontSize(
      crossExtent: 4,
      mainExtent: 40,
      characters: 4,
      bodyContext: true,
    );
    expect(outside, closeTo(4.651, .001));
    expect(body, closeTo(8.971, .001));
  });

  test('one inferred sound-effect cue does not discard ordinary dialogue', () {
    const bubble = [
      NormalizedPoint(0.55, 0.08),
      NormalizedPoint(0.9, 0.08),
      NormalizedPoint(0.9, 0.7),
      NormalizedPoint(0.55, 0.7),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'body-1', '今日はいい日', 0.8, 0.15, 0.04, 0.24, 0,
        bubbleGroupId: 7, bubblePolygon: bubble,
      ),
      _positionedRegion(
        'body-2', '散歩しよう', 0.7, 0.15, 0.04, 0.24, 1,
        bubbleGroupId: 7, bubblePolygon: bubble,
      ),
      _positionedRegion(
        'body-3', 'そうですね', 0.6, 0.15, 0.04, 0.24, 2,
        bubbleGroupId: 7, bubblePolygon: bubble,
      ),
      _positionedRegion(
        'missed-bubble', '普通の長い台詞', 0.12, 0.18, 0.08, 0.18, 3,
      ),
    ]);
    final units = ComicTranslationUnit.fromOcr(artifact);
    expect(units.expand((unit) => unit.regionIds), contains('missed-bubble'));
  });

  test('combined size and script evidence still filters inferred sound effect', () {
    const bubble = [
      NormalizedPoint(0.55, 0.08),
      NormalizedPoint(0.9, 0.08),
      NormalizedPoint(0.9, 0.7),
      NormalizedPoint(0.55, 0.7),
    ];
    final artifact = _ocrArtifact([
      _positionedRegion(
        'body-1', '今日はいい日', 0.8, 0.15, 0.04, 0.24, 0,
        bubbleGroupId: 7, bubblePolygon: bubble,
      ),
      _positionedRegion(
        'body-2', '散歩しよう', 0.7, 0.15, 0.04, 0.24, 1,
        bubbleGroupId: 7, bubblePolygon: bubble,
      ),
      _positionedRegion(
        'body-3', 'そうですね', 0.6, 0.15, 0.04, 0.24, 2,
        bubbleGroupId: 7, bubblePolygon: bubble,
      ),
      _positionedRegion('sfx', 'ドンドン', 0.12, 0.18, 0.1, 0.24, 3),
    ]);
    final units = ComicTranslationUnit.fromOcr(artifact);
    expect(units.expand((unit) => unit.regionIds), isNot(contains('sfx')));
    expect(
      ComicTranslationUnit.fromOcr(
        artifact,
        translateSoundEffects: true,
      ).expand((unit) => unit.regionIds),
      contains('sfx'),
    );
  });

  test('sound effects are submitted only when explicitly enabled', () {
    final artifact = _ocrArtifact([
      _ocrRegion(
        'sfx',
        'ドン',
        0,
        1,
        kind: ComicTextKind.soundEffect,
      ),
    ]);
    expect(ComicTranslationUnit.fromOcr(artifact), isEmpty);
    expect(
      ComicTranslationUnit.fromOcr(
        artifact,
        translateSoundEffects: true,
      ).single.sourceLines,
      ['ドン'],
    );
  });

  test('uncertain oversized lettering keeps its original with sound effects off', () {
    for (final text in ['ガ7', 'ぜっ', '哲']) {
      final artifact = _ocrArtifact([
        _positionedRegion('body-1', '今日はいい日', .8, .15, .04, .24, 0,
          bubbleGroupId: 7),
        _positionedRegion('body-2', '散歩しよう', .7, .15, .04, .24, 1,
          bubbleGroupId: 7),
        _positionedRegion('body-3', 'そうですね', .6, .15, .04, .24, 2,
          bubbleGroupId: 7),
        _positionedRegion('body-4', 'もう夕方です', .5, .15, .04, .24, 3,
          bubbleGroupId: 7),
        _positionedRegion('lettering', text, .12, .18, .16, .24, 4,
          confidence: .55),
      ]);
      final request = ComicTranslationRequest(ocr: artifact,
        targetLanguage: 'zh-CN', previousPages: const []);
      expect(request.units.expand((unit) => unit.regionIds),
        isNot(contains('lettering')), reason: text);
      final expanded = request.expandUnitTranslations(ComicTranslationResult({
        for (final unit in request.units)
          unit.id: [for (final _ in unit.sourceLines) '正文'],
      }));
      expect(expanded['lettering'], '', reason: text);
      expect(ComicTranslationUnit.fromOcr(artifact, translateSoundEffects: true)
        .expand((unit) => unit.regionIds), contains('lettering'));
    }
  });

  test('lettering guard preserves short dialogue, reliable text and numbers', () {
    final artifact = _ocrArtifact([
      _positionedRegion('body', '今日はいい天気ですね', .8, .1, .04, .32, 0,
        bubbleGroupId: 7),
      _positionedRegion('large-reliable', 'やめろ', .1, .1, .14, .24, 1),
      _positionedRegion('small-uncertain', 'えっ', .4, .1, .04, .08, 2,
        confidence: .5),
      _positionedRegion('breath', 'はぁ…', .4, .6, .04, .12, 3,
        confidence: .5),
      _positionedRegion('bubble-short', 'え', .7, .6, .14, .24, 4,
        bubbleGroupId: 8, confidence: .5),
      _positionedRegion('number', '7', .1, .5, .04, .04, 5),
      _positionedRegion('bubble-number', '7', .1, .7, .04, .04, 6,
        bubbleGroupId: 9, confidence: .7),
      _positionedRegion('digit-fragment', '7', .4, .9, .04, .04, 7,
        confidence: .7),
      _positionedRegion('two-digit-fragment', '51', .15, .88, .16, .1, 8,
        confidence: .6485),
      _positionedRegion('reliable-number', '51', .6, .4, .06, .04, 9),
      _positionedRegion('bubble-two-digit', '51', .1, .3, .04, .04, 10,
        bubbleGroupId: 10, confidence: .5),
    ]);
    final ids = ComicTranslationUnit.fromOcr(artifact)
        .expand((unit) => unit.regionIds).toSet();
    expect(ids, containsAll(['body', 'large-reliable', 'small-uncertain',
      'breath', 'bubble-short', 'number', 'bubble-number',
      'reliable-number', 'bubble-two-digit']));
    expect(ids, isNot(contains('digit-fragment')));
    expect(ids, isNot(contains('two-digit-fragment')));
  });

  test('weak large art cannot define its own body size reference', () {
    for (final orientation in ComicTextOrientation.values) {
      final artifact = _ocrArtifact([
        _positionedRegion('art', 'H7', .502, .065, .118, .167, 0,
          orientation: orientation, confidence: .4344),
        _positionedRegion('body-1', 'それじゃ', .639, .174, .027, .071, 1),
        _positionedRegion('body-2', 'また明日', .593, .307, .022, .068, 2),
        _positionedRegion('body-3', 'よろしくね', .575, .308, .022, .079, 3),
        _positionedRegion('body-4', 'はい', .210, .712, .025, .038, 4),
        _positionedRegion('body-5', 'また明日', .166, .810, .022, .066, 5),
      ]);
      final ids = ComicTranslationUnit.fromOcr(artifact)
          .expand((unit) => unit.regionIds).toSet();
      expect(ids, containsAll(['body-1', 'body-2', 'body-3', 'body-4', 'body-5']));
      expect(ids, isNot(contains('art')), reason: orientation.name);
      expect(ComicTranslationUnit.fromOcr(artifact, translateSoundEffects: true)
          .expand((unit) => unit.regionIds), contains('art'));
    }
  });

  test('tiny weak drawing marks need a reliable body size reference', () {
    final mark = _positionedRegion('mark', '1用', .425, .211, .013, .010, 1,
      orientation: ComicTextOrientation.horizontal, confidence: .3962);
    final artifact = _ocrArtifact([
      _positionedRegion('body', 'また明日よろしくね', .8, .1, .024, .2, 0),
      mark,
      _positionedRegion('reliable-tiny', '1用', .5, .7, .013, .010, 2,
        orientation: ComicTextOrientation.horizontal),
      _positionedRegion('bubble-tiny', '1用', .4, .9, .013, .010, 3,
        bubbleGroupId: 7, confidence: .3962),
      _positionedRegion('short-answer', 'えっ', .05, .1, .024, .042, 4,
        confidence: .3962),
    ]);
    for (final soundEffects in [false, true]) {
      final ids = ComicTranslationUnit.fromOcr(artifact,
          translateSoundEffects: soundEffects)
          .expand((unit) => unit.regionIds).toSet();
      expect(ids, containsAll(['body', 'reliable-tiny', 'bubble-tiny', 'short-answer']));
      expect(ids, isNot(contains('mark')));
    }
    expect(ComicTranslationUnit.fromOcr(_ocrArtifact([mark])).single.regionIds,
      ['mark'], reason: 'an uncertain page cannot provide a trusted size reference');
  });

  test('uncertain lone marks filling a detected contour preserve the drawing', () {
    const contour = [NormalizedPoint(.51, .09973), NormalizedPoint(.56625, .09973),
      NormalizedPoint(.56625, .14515), NormalizedPoint(.51, .14515)];
    ComicOcrRegion mark({double confidence = .5899, bool roomy = false}) =>
      _positionedRegion('eye', '可', .521, .104, .045, .028, 0,
        bubbleGroupId: 0, bubblePolygon: roomy ? const [
          NormalizedPoint(.46, .06), NormalizedPoint(.62, .06),
          NormalizedPoint(.62, .18), NormalizedPoint(.46, .18),
        ] : contour, confidence: confidence, sourceMaskPolygons: const [[
          NormalizedPoint(.51875, .1024), NormalizedPoint(.5675, .1024),
          NormalizedPoint(.5675, .1291), NormalizedPoint(.51875, .1291),
        ]]);
    for (final soundEffects in [false, true]) {
      final units = ComicTranslationUnit.fromOcr(_ocrArtifact([mark()]),
        translateSoundEffects: soundEffects);
      expect(units, isEmpty, reason: 'drawing noise is independent of sound effects');
    }
    expect(ComicTranslationUnit.fromOcr(_ocrArtifact([mark(confidence: .95)])),
      hasLength(1), reason: 'a tight contour alone cannot reject reliable text');
    expect(ComicTranslationUnit.fromOcr(_ocrArtifact([mark(roomy: true)])),
      hasLength(1), reason: 'weak short answers in a roomy balloon stay eligible');
    final shared = _ocrArtifact([mark(),
      _positionedRegion('dialogue', 'そうですね', .52, .16, .04, .2, 1,
        bubbleGroupId: 0, bubblePolygon: contour),
    ]);
    expect(ComicTranslationUnit.fromOcr(shared).expand((unit) => unit.regionIds),
      containsAll(['eye', 'dialogue']),
      reason: 'a separate mark sharing dialogue space is not a lone false balloon');
    final request = ComicTranslationRequest(ocr: _ocrArtifact([mark()]),
      targetLanguage: 'zh-CN', previousPages: const []);
    expect(request.expandUnitTranslations(const ComicTranslationResult({}))['eye'], '',
      reason: 'skipped drawings must not receive an erasing or text overlay');
  });

  test('layout and translation resolver share group key and band order', () {
    final artifact = _ocrArtifact([
      _positionedRegion('left', '左', 0.42, 0.12, 0.08, 0.42, 0),
      _positionedRegion('right-bottom', '下', 0.55, 0.34, 0.08, 0.2, 1),
      _positionedRegion('right-top', '上', 0.55, 0.1, 0.08, 0.2, 2),
    ]);
    final grouping = ComicTextGrouping(
      imageWidth: artifact.imageWidth,
      imageHeight: artifact.imageHeight,
      sourceLanguage: artifact.sourceLanguage,
    );
    final groups = grouping.resolve(artifact.regions.map((region) =>
        ComicTextRegion(
          value: region,
          id: region.id,
          text: region.text,
          polygon: region.polygon,
          sourceMaskPolygons: region.sourceMaskPolygons,
          orientation: region.orientation,
          backgroundArgb: region.backgroundArgb,
          bubbleGroupId: region.bubbleGroupId,
          bubblePolygon: region.bubblePolygon,
        )).toList());
    expect(groups.single.key, ComicTranslationUnit.fromOcr(artifact).single.id);
    expect(groups.single.bands.map((band) =>
        band.regions.map((region) => region.id).toList()).toList(), [
      ['right-top', 'right-bottom'],
      ['left'],
    ]);
  });

  test('one bubble is translated jointly and split back into OCR columns', () async {
    final image = File('${temp.path}/grouped-page.bin');
    await image.writeAsBytes(List<int>.generate(257, (i) => i & 0xff));
    final identity = ComicTranslationPageIdentity(
      imageKey: image.uri.toString(),
      sourceKey: 'local',
      comicId: 'grouped-comic',
      chapterId: 'chapter',
      pageIndex: 0,
      mediaKind: ComicTranslationMediaKind.staticImage,
    );
    final ocr = _OcrEngine(
      version: 'grouped',
      regions: [
        _ocrRegion('r2', '三', 0, 9, left: 0.1),
        _ocrRegion('r0', '一', 2, 9, left: 0.7),
        _ocrRegion('r1', '二', 1, 9, left: 0.4),
        _ocrRegion(
          'sfx',
          'BOOM',
          3,
          10,
          kind: ComicTextKind.soundEffect,
        ),
      ],
    );
    final translator = _TranslationEngine.lines(const ['译一', '译二', '译三']);
    final registry = ComicTranslationEngineRegistry()
      ..ocrEngine = ocr
      ..translationEngine = translator;
    final session = ComicTranslationSession(
      enabled: true,
      sourceLanguage: 'ko',
      targetLanguage: 'zh-CN',
      engines: registry,
    );
    session.reportPages(
      current: [identity],
      interaction: ComicTranslationInteraction.idle,
    );
    final state = await _waitFor(session, identity);
    final artifact = state.artifact!;
    final unit = translator.lastRequest!.units.single;
    expect(unit.id, 'regions:r0,r1,r2');
    expect(unit.regionIds, ['r0', 'r1', 'r2']);
    expect(unit.sourceLines, ['一', '二', '三']);
    final translated = {
      for (final region in artifact.regions)
        region.ocrRegionId: region.translatedText,
    };
    expect(translated, {
      'r2': '译三',
      'r0': '译一',
      'r1': '译二',
      'sfx': '',
    });
    expect(state.cleanOverlayPng, isNull);
    session.dispose();
  });

  test('one session uses the mean font scale for every text block', () async {
    final image = File('${temp.path}/typography-page.bin');
    await image.writeAsBytes(List<int>.generate(258, (i) => i & 0xff));
    final identity = ComicTranslationPageIdentity(
      imageKey: image.uri.toString(),
      sourceKey: 'local',
      comicId: 'typography-comic',
      chapterId: 'chapter',
      pageIndex: 0,
      mediaKind: ComicTranslationMediaKind.staticImage,
    );
    final registry = ComicTranslationEngineRegistry()
      ..ocrEngine = _OcrEngine(
        version: 'typography',
        regions: [
          _ocrRegion('r0', '四个文字', 0, 4, left: 0.6),
          _ocrRegion('r1', '一', 1, 4, left: 0.3),
        ],
      )
      ..translationEngine = _TranslationEngine.lines(const ['中', '四个文字']);
    final session = ComicTranslationSession(
      enabled: true,
      sourceLanguage: 'ja',
      targetLanguage: 'zh-CN',
      engines: registry,
    );
    session.reportPages(
      current: [identity],
      interaction: ComicTranslationInteraction.idle,
    );
    await _waitFor(session, identity);
    expect(session.fontScaleListenable.value, closeTo(1.01, 0.0001));
    session.dispose();
  });

  test('one translation result is split back by source column weight', () {
    final ocr = ComicOcrArtifact(
      contentDigest: 'digest',
      engineId: 'ocr',
      modelVersion: '1',
      sourceLanguage: 'ja',
      imageWidth: 100,
      imageHeight: 100,
      mediaKind: ComicTranslationMediaKind.staticImage,
      animatedMode: AnimatedTranslationMode.posterFrame,
      regions: [
        _ocrRegion('right', '右右右', 0, 1, left: 0.7),
        _ocrRegion('left', '左', 1, 1, left: 0.3),
      ],
    );
    final request = ComicTranslationRequest(
      ocr: ocr,
      targetLanguage: 'zh-CN',
      previousPages: const [],
    );
    final unit = request.units.single;
    final expanded = request.expandUnitTranslations(ComicTranslationResult({
      unit.id: const ['甲乙丙丁'],
    }));
    expect(unit.regionIds.map((id) => expanded[id]).toList(), ['甲乙丙', '丁']);
  });

  test('repeated full balloon translation is distributed only once', () {
    final request = ComicTranslationRequest(
      ocr: _ocrArtifact([
        _ocrRegion('right', '好きなの', 0, 7, left: 0.55),
        _ocrRegion('left', 'とっていいわよ', 1, 7, left: 0.3),
      ]),
      targetLanguage: 'zh-CN',
      previousPages: const [],
    );
    final unit = request.units.single;
    final expanded = request.expandUnitTranslations(ComicTranslationResult({
      unit.id: const ['喜欢哪个就拿哪个', '喜欢哪个就拿哪个'],
    }));
    final values = unit.regionIds.map((id) => expanded[id]!).toList();
    expect(values.join(), '喜欢哪个就拿哪个');
    expect(values.every((value) => value.isNotEmpty), true);
  });

  test('translation keeps source punctuation without adding new marks', () {
    final request = ComicTranslationRequest(
      ocr: _ocrArtifact([
        _ocrRegion('punctuation', 'そう、そう？', 0, 7),
      ]),
      targetLanguage: 'zh-CN',
      previousPages: const [],
    );
    final unit = request.units.single;
    final expanded = request.expandUnitTranslations(ComicTranslationResult({
      unit.id: const ['对，对吧！！'],
    }));
    expect(expanded['punctuation'], '对、对吧？');
  });

  test('source three-dot ellipsis replaces translated punctuation', () {
    final request = ComicTranslationRequest(
      ocr: _ocrArtifact([
        _ocrRegion('ellipsis', '待って・・・', 0, 7),
      ]),
      targetLanguage: 'zh-CN',
      previousPages: const [],
    );
    final unit = request.units.single;
    final expanded = request.expandUnitTranslations(ComicTranslationResult({
      unit.id: const ['等等……。'],
    }));
    expect(expanded['ellipsis'], '等等・・・');
  });

  test('post-cleanup blank lines preserve source without failing the page', () {
    final request = ComicTranslationRequest(
      ocr: _ocrArtifact([
        _ocrRegion('drawing', 'て', 0, 0),
        _ocrRegion('right', 'ごめん', 1, 1),
        _ocrRegion('left', '有希ちゃん', 2, 1),
      ]),
      targetLanguage: 'zh-CN',
      previousPages: const [],
      units: const [
        ComicTranslationUnit(id: 'drawing', regionIds: ['drawing'],
          sourceLines: ['て'], orientation: ComicTextOrientation.horizontal,
          bandRegionIds: [['drawing']]),
        ComicTranslationUnit(id: 'dialogue', regionIds: ['right', 'left'],
          sourceLines: ['ごめん', '有希ちゃん'], orientation: ComicTextOrientation.vertical,
          bandRegionIds: [['right', 'left']]),
      ],
    );
    final expanded = request.expandUnitTranslations(ComicTranslationResult({
      'drawing': const ['…'],
      'dialogue': const ['抱歉', '…'],
    }));
    expect(expanded, {
      'drawing': comicTranslationBreakMarker,
      'right': '抱歉',
      'left': comicTranslationBreakMarker,
    });
  });

  test('missing and raw empty translation responses still fail', () {
    final request = ComicTranslationRequest(
      ocr: _ocrArtifact([_ocrRegion('text', 'ごめん', 0, 0)]),
      targetLanguage: 'zh-CN',
      previousPages: const [],
    );
    final id = request.units.single.id;
    for (final lines in <List<String>>[[], [''], ['  '], ['抱歉', '']]) {
      expect(() => request.expandUnitTranslations(
        ComicTranslationResult({id: lines})), throwsStateError);
    }
    expect(() => request.expandUnitTranslations(
      ComicTranslationResult(const {})), throwsStateError);
  });

  test('translation break marker survives while added punctuation is removed', () {
    final request = ComicTranslationRequest(
      ocr: _ocrArtifact([
        _ocrRegion('break', '長い文', 0, 7),
      ]),
      targetLanguage: 'zh-CN',
      previousPages: const [],
    );
    final unit = request.units.single;
    final expanded = request.expandUnitTranslations(ComicTranslationResult({
      unit.id: const ['第一句$comicTranslationBreakMarker第二句。'],
    }));
    expect(
      expanded['break'],
      '第一句$comicTranslationBreakMarker第二句',
    );
  });

  test('OCR benchmark runs without a remote translation backend', () async {
    final image = File('${temp.path}/benchmark.bin');
    await image.writeAsBytes(List<int>.generate(128, (i) => i));
    final ocr = _OcrEngine();
    final registry = ComicTranslationEngineRegistry()..ocrEngine = ocr;
    final result = await ComicTranslationBenchmark(engines: registry).run(
      pages: [
        ComicTranslationPageIdentity(
          imageKey: image.uri.toString(),
          sourceKey: 'benchmark',
          comicId: 'benchmark',
          chapterId: '0',
          pageIndex: 0,
          mediaKind: ComicTranslationMediaKind.staticImage,
        ),
      ],
      sourceLanguage: 'ja',
      targetLanguage: 'zh-CN',
      diagnoseGrouping: false,
    );
    expect(result.translationMeasured, false);
    expect(result.samples.single.regionCount, 1);
    expect(result.samples.single.relationDiagnostics, isEmpty);
    expect(result.samples.single.bubbleBoundaryDiagnostics, isEmpty);
    expect(ocr.loads, 1);
    expect(ocr.unloads, 1);
  });

  test('OCR benchmark can temporarily bypass configured translation', () async {
    final image = File('${temp.path}/benchmark-ocr-only.bin');
    await image.writeAsBytes(List<int>.generate(128, (i) => i));
    final ocr = _OcrEngine();
    final translator = _TranslationEngine();
    final registry = ComicTranslationEngineRegistry()
      ..ocrEngine = ocr
      ..translationEngine = translator;
    final result = await ComicTranslationBenchmark(engines: registry).run(
      pages: [ComicTranslationPageIdentity(
        imageKey: image.uri.toString(),
        sourceKey: 'benchmark',
        comicId: 'benchmark',
        chapterId: '0',
        pageIndex: 0,
        mediaKind: ComicTranslationMediaKind.staticImage,
      )],
      sourceLanguage: 'ja',
      targetLanguage: 'zh-CN',
      runTranslation: false,
    );
    expect(result.translationMeasured, false);
    expect(translator.calls, 0);
    expect(translator.loads, 0);
  });

  test('animated page uses the reserved unsupported state', () async {
    final identity = ComicTranslationPageIdentity(
      imageKey: 'animated.webp',
      sourceKey: 'source',
      comicId: 'comic',
      chapterId: '0',
      pageIndex: 0,
      mediaKind: ComicTranslationMediaKind.animatedImage,
    );
    final session = ComicTranslationSession(
      enabled: true,
      sourceLanguage: 'ja',
      targetLanguage: 'zh-CN',
    );
    session.reportPages(
      current: [identity],
      interaction: ComicTranslationInteraction.idle,
    );
    expect(
      session.listenable(identity).value.phase,
      ComicTranslationPhase.unsupportedMedia,
    );
    session.dispose();
  });

  test('WebP container inspection rejects animation without source heuristics', () async {
    final image = File('${temp.path}/animated.webp');
    await image.writeAsBytes([
      ...'RIFF'.codeUnits,
      12, 0, 0, 0,
      ...'WEBP'.codeUnits,
      ...'ANIM'.codeUnits,
      0, 0, 0, 0,
    ]);
    final identity = ComicTranslationPageIdentity(
      imageKey: image.uri.toString(),
      sourceKey: 'local',
      comicId: 'comic',
      chapterId: 'chapter',
      pageIndex: 1,
      mediaKind: ComicTranslationMediaKind.staticImage,
    );
    final ocr = _OcrEngine();
    final registry = ComicTranslationEngineRegistry()
      ..ocrEngine = ocr
      ..translationEngine = _TranslationEngine();
    final session = ComicTranslationSession(
      enabled: true,
      sourceLanguage: 'ja',
      targetLanguage: 'zh-CN',
      engines: registry,
    );
    session.reportPages(
      current: [identity],
      interaction: ComicTranslationInteraction.idle,
    );
    await _waitForPhase(
      session,
      identity,
      ComicTranslationPhase.unsupportedMedia,
    );
    expect(ocr.calls, 0);
    session.dispose();
  });
}

Future<ComicTranslationPageState> _waitFor(
  ComicTranslationSession session,
  ComicTranslationPageIdentity identity,
) {
  final listenable = session.listenable(identity);
  if (listenable.value.phase == ComicTranslationPhase.ready) {
    return Future.value(listenable.value);
  }
  final completer = Completer<ComicTranslationPageState>();
  void listener() {
    final state = listenable.value;
    if (state.phase == ComicTranslationPhase.ready) {
      listenable.removeListener(listener);
      completer.complete(state);
    } else if (state.phase == ComicTranslationPhase.failed) {
      listenable.removeListener(listener);
      completer.completeError(state.error!);
    }
  }
  listenable.addListener(listener);
  return completer.future;
}

Future<void> _waitForPhase(
  ComicTranslationSession session,
  ComicTranslationPageIdentity identity,
  ComicTranslationPhase phase,
) {
  final listenable = session.listenable(identity);
  if (listenable.value.phase == phase) return Future.value();
  final completer = Completer<void>();
  void listener() {
    if (listenable.value.phase != phase) return;
    listenable.removeListener(listener);
    completer.complete();
  }
  listenable.addListener(listener);
  return completer.future;
}

final class _DeepLAdapter implements HttpClientAdapter {
  final Object Function(RequestOptions request) response;
  final List<RequestOptions> requests = [];

  RequestOptions? get request => requests.lastOrNull;

  _DeepLAdapter(Object response) : response = ((_) => response);

  _DeepLAdapter.generated(this.response);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(response(options)),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

class _OcrEngine implements ComicOcrEngine {
  final String version;
  final List<ComicOcrRegion>? regions;
  final Completer<void>? recognizeStarted;
  final Completer<void>? recognizeGate;
  final String? detectedSourceLanguage;
  final List<String> languages = [];
  final List<ComicOcrInput> inputs = [];
  int calls = 0;
  int loads = 0;
  int unloads = 0;

  _OcrEngine({
    this.version = '1',
    this.regions,
    this.recognizeStarted,
    this.recognizeGate,
    this.detectedSourceLanguage,
  });

  @override
  String get id => 'test-ocr';

  @override
  String get modelVersion => version;

  @override
  bool get supportsAnimatedPosterFrame => false;

  @override
  Future<void> load(String sourceLanguage) async => loads++;

  @override
  Future<ComicOcrArtifact> recognize(ComicOcrInput input) async {
    calls++;
    inputs.add(input);
    languages.add(input.sourceLanguage);
    if (recognizeStarted?.isCompleted == false) recognizeStarted!.complete();
    if (recognizeGate != null) await recognizeGate!.future;
    return ComicOcrArtifact(
      contentDigest: input.contentDigest,
      engineId: id,
      modelVersion: modelVersion,
      sourceLanguage: detectedSourceLanguage ?? input.sourceLanguage,
      imageWidth: 100,
      imageHeight: 100,
      mediaKind: ComicTranslationMediaKind.staticImage,
      animatedMode: AnimatedTranslationMode.posterFrame,
      regions: regions ?? const [
        ComicOcrRegion(
          id: 'r0',
          polygon: [
            NormalizedPoint(0.1, 0.1),
            NormalizedPoint(0.9, 0.1),
            NormalizedPoint(0.9, 0.5),
            NormalizedPoint(0.1, 0.5),
          ],
          text: 'こんにちは',
          confidence: 0.9,
          orientation: ComicTextOrientation.vertical,
          kind: ComicTextKind.dialogue,
          readingOrder: 0,
          sourceMaskPolygons: [
            [
              NormalizedPoint(0.12, 0.12),
              NormalizedPoint(0.2, 0.12),
              NormalizedPoint(0.2, 0.3),
              NormalizedPoint(0.12, 0.3),
            ],
          ],
          backgroundArgb: 0xFFFFFFFF,
          foregroundArgb: 0xFF202020,
          bubbleGroupId: 3,
          bubblePolygon: [
            NormalizedPoint(0.05, 0.05),
            NormalizedPoint(0.95, 0.05),
            NormalizedPoint(0.95, 0.55),
            NormalizedPoint(0.05, 0.55),
          ],
          bubbleCandidatePolygon: [
            NormalizedPoint(0.04, 0.04),
            NormalizedPoint(0.96, 0.04),
            NormalizedPoint(0.96, 0.56),
            NormalizedPoint(0.04, 0.56),
          ],
        ),
      ],
      cleanOverlayPng: regions == null
          ? Uint8List.fromList(const [1, 2, 3])
          : null,
    );
  }

  @override
  Future<void> unload() async => unloads++;
}

final class _SwitchingOcrEngine extends _OcrEngine implements ComicOcrLanguageSwitcher {
  int switches = 0;

  @override
  String recognitionKey(String language) => language == 'ko' ? 'korean' : 'default';

  @override
  String modelVersionForLanguage(String language) => modelVersion;

  @override
  Future<void> selectLanguage(String language) async { switches++; }
}

final class _TranslationEngine implements ComicTextTranslationEngine {
  final String translatedText;
  final List<String>? translatedLines;
  @override
  final ComicTranslationContextMode contextMode;
  int calls = 0;
  int loads = 0;
  int unloads = 0;
  ComicTranslationRequest? lastRequest;
  final Completer<void>? translateStarted;
  final Completer<void>? translateGate;

  _TranslationEngine({
    this.contextMode = ComicTranslationContextMode.previousPages,
    this.translateStarted,
    this.translateGate,
  }) : translatedText = '你好', translatedLines = null;

  _TranslationEngine.lines(this.translatedLines)
      : translatedText = '',
        translateStarted = null,
        translateGate = null,
        contextMode = ComicTranslationContextMode.previousPages;

  @override
  ComicTranslationEngineIdentity identityFor(
    ComicTranslationRequest request,
  ) => const ComicTranslationEngineIdentity(
    id: 'test-translation',
    modelVersion: '1',
  );

  @override
  Future<void> load() async => loads++;

  @override
  Future<ComicTranslationResult> translate(
    ComicTranslationRequest request,
  ) async {
    calls++;
    lastRequest = request;
    if (translateStarted?.isCompleted == false) translateStarted!.complete();
    if (translateGate != null) await translateGate!.future;
    return ComicTranslationResult({
      for (final unit in request.units)
        unit.id: translatedLines ??
            List.filled(unit.regionIds.length, translatedText),
    });
  }

  @override
  Future<void> unload() async => unloads++;
}

ComicOcrRegion _ocrRegion(
  String id,
  String text,
  int readingOrder,
  int bubbleGroupId, {
  ComicTextKind kind = ComicTextKind.dialogue,
  double left = 0.1,
}) => ComicOcrRegion(
  id: id,
  polygon: [
    NormalizedPoint(left, 0.1),
    NormalizedPoint(left + 0.2, 0.1),
    NormalizedPoint(left + 0.2, 0.5),
    NormalizedPoint(left, 0.5),
  ],
  text: text,
  confidence: 0.9,
  orientation: ComicTextOrientation.vertical,
  kind: kind,
  readingOrder: readingOrder,
  sourceMaskPolygons: const [],
  bubbleGroupId: bubbleGroupId,
);

ComicOcrArtifact _ocrArtifact(
  List<ComicOcrRegion> regions, {
  String sourceLanguage = 'ja',
}) => ComicOcrArtifact(
  contentDigest: 'content',
  engineId: 'test',
  modelVersion: '1',
  sourceLanguage: sourceLanguage,
  imageWidth: 1000,
  imageHeight: 1000,
  mediaKind: ComicTranslationMediaKind.staticImage,
  animatedMode: AnimatedTranslationMode.posterFrame,
  regions: regions,
);

ComicOcrRegion _positionedRegion(
  String id,
  String text,
  double left,
  double top,
  double width,
  double height,
  int readingOrder, {
  int? bubbleGroupId,
  List<NormalizedPoint>? bubblePolygon,
  ComicTextOrientation orientation = ComicTextOrientation.vertical,
  List<List<NormalizedPoint>> sourceMaskPolygons = const [],
  int backgroundArgb = 0xffffffff,
  double confidence = .9,
}) => ComicOcrRegion(
  id: id,
  polygon: [
    NormalizedPoint(left, top),
    NormalizedPoint(left + width, top),
    NormalizedPoint(left + width, top + height),
    NormalizedPoint(left, top + height),
  ],
  text: text,
  confidence: confidence,
  orientation: orientation,
  kind: ComicTextKind.dialogue,
  readingOrder: readingOrder,
  sourceMaskPolygons: sourceMaskPolygons,
  backgroundArgb: backgroundArgb,
  bubbleGroupId: bubbleGroupId,
  bubblePolygon: bubblePolygon,
);

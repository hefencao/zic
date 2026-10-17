import 'package:comic_translation/comic_translation.dart';
import 'package:file_selector/file_selector.dart';

import 'startup_platform.dart';

Future<String> testComicTranslationText({
  required String sourceLanguage,
  required String targetLanguage,
  required String backend,
  required String localModel,
}) async {
  if (sourceLanguage == 'auto') {
    sourceLanguage = backend == 'local'
        ? ComicLocalTranslationModelManager.instance.modelById(localModel)
            ?.sourceLanguages.firstOrNull ?? 'en'
        : 'en';
  }
  final text = switch (sourceLanguage) {
    'ja' => 'こんにちは',
    'ko' => '안녕하세요',
    'zh' => '你好',
    _ => 'Hello',
  };
  final timer = Stopwatch()..start();
  final result = await ComicTranslationEngineRegistry.instance.translateConfigured(
    ComicTranslationRequest(
      ocr: ComicOcrArtifact(
        contentDigest: 'connection-test', engineId: 'test', modelVersion: '1', sourceLanguage: sourceLanguage,
        imageWidth: 1, imageHeight: 1, mediaKind: ComicTranslationMediaKind.staticImage,
        animatedMode: AnimatedTranslationMode.posterFrame, regions: const [],
      ),
      units: [ComicTranslationUnit(id: 'test', regionIds: const ['test'], sourceLines: [text],
        orientation: ComicTextOrientation.horizontal, bandRegionIds: const [['test']])],
      targetLanguage: targetLanguage, previousPages: const [],
    ),
  );
  return '${timer.elapsedMilliseconds} ms\n$text → ${result.translations['test']?.join('\n') ?? ''}';
}

Future<String?> selectComicTranslationTestImage({
  required String sourceLanguage,
  required String targetLanguage,
  required bool runTranslation,
  ComicOcrParameters? ocrParameters,
}) async {
  await attachAndroidPlugin('file_selector_android');
  final file = await openFile(acceptedTypeGroups: [const XTypeGroup(
    label: '图片', extensions: ['png', 'jpg', 'jpeg', 'webp'],
    mimeTypes: ['image/png', 'image/jpeg', 'image/webp'],
  )]);
  if (file == null) return null;
  final result = await benchmarkComicTranslationImage(
    copyImage: file.saveTo,
    sourceLanguage: sourceLanguage,
    targetLanguage: targetLanguage,
    runTranslation: runTranslation,
    ocrParameters: ocrParameters ?? ComicOcrParameters.fromSettings(ComicTranslationSettings.instance.values),
  );
  final sample = result.samples.single;
  final metrics = sample.translationMetrics;
  return 'OCR ${sample.ocrTime.inMilliseconds} ms · 翻译 ${sample.translationTime.inMilliseconds} ms\n'
      '${sample.regionCount} 个区域 · ${sample.bubbleCount} 个气泡 · '
      'RSS ${(result.maxObservedRss / 1048576).round()} MB\n'
      '${metrics == null ? '' : '${metrics.unitCount} 个翻译单元 · ${metrics.batchDurations.length} 个批次\n'}'
      '${List.generate(sample.regionCount, (i) => '${i + 1}. ${sample.sourceTexts[i]}\n→ ${sample.translatedTexts[i]}').join('\n\n')}';
}

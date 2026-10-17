import 'ocr_parameters.dart';

enum ComicTranslationInteraction { idle, dragging, settling, scrolling, jumping }

final class ComicTranslationPolicy {
  final Duration dragSubmissionDelay;
  final int prefetchPages;
  final int cachePrefetchPages;
  final int imagePreloadPages;
  final ComicOcrParameters ocrParameters;
  final int contextPages;
  final bool translateSoundEffects;
  final bool useCleanOverlay;

  const ComicTranslationPolicy({
    this.dragSubmissionDelay = const Duration(milliseconds: 180),
    this.prefetchPages = 4,
    this.cachePrefetchPages = 4,
    this.imagePreloadPages = 4,
    this.ocrParameters = const ComicOcrParameters(),
    this.contextPages = 2,
    this.translateSoundEffects = false,
    this.useCleanOverlay = true,
  }) : assert(prefetchPages >= 0),
       assert(cachePrefetchPages >= 0),
       assert(imagePreloadPages >= 0),
       assert(contextPages >= 0);

  int get maxAnalysisSide => ocrParameters.maxAnalysisSide;

  ComicTranslationPolicy withPrefetch({required int pages, required int cachedPages}) =>
      ComicTranslationPolicy(
        dragSubmissionDelay: dragSubmissionDelay, prefetchPages: pages,
        cachePrefetchPages: cachedPages, imagePreloadPages: imagePreloadPages,
        ocrParameters: ocrParameters, contextPages: contextPages,
        translateSoundEffects: translateSoundEffects, useCleanOverlay: useCleanOverlay,
      );

  int effectiveImagePreloadPages(int configured) =>
      configured < imagePreloadPages ? imagePreloadPages : configured;

  Duration submissionDelay(ComicTranslationInteraction interaction) =>
      switch (interaction) {
        ComicTranslationInteraction.dragging ||
        ComicTranslationInteraction.scrolling => dragSubmissionDelay,
        _ => Duration.zero,
      };

  int priority({required int distance, required bool current}) =>
      current ? 1000 : 500 - distance;
}

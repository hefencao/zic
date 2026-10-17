import 'dart:convert';

final class ComicOcrParameters {
  const ComicOcrParameters({
    this.maxAnalysisSide = 1600,
    this.detectionThreshold = .45,
    this.recognitionThreshold = .35,
    this.unclipRatio = 1.4,
  }) : assert(maxAnalysisSide >= 320 && maxAnalysisSide <= 4096),
       assert(detectionThreshold >= .1 && detectionThreshold <= .9),
       assert(recognitionThreshold >= .1 && recognitionThreshold <= .9),
       assert(unclipRatio >= 1 && unclipRatio <= 3);

  final int maxAnalysisSide;
  final double detectionThreshold;
  final double recognitionThreshold;
  final double unclipRatio;

  factory ComicOcrParameters.fromSettings(Map<String, Object?> values) => ComicOcrParameters(
    maxAnalysisSide: (values['ocrMaxAnalysisSide'] as num? ?? 1600).toInt().clamp(320, 4096),
    detectionThreshold: (values['ocrDetectionThreshold'] as num? ?? .45).toDouble().clamp(.1, .9),
    recognitionThreshold: (values['ocrRecognitionThreshold'] as num? ?? .35).toDouble().clamp(.1, .9),
    unclipRatio: (values['ocrUnclipRatio'] as num? ?? 1.4).toDouble().clamp(1, 3),
  );

  // Preserve existing default OCR/MT identities; only changed analysis has a
  // new identity. Scheduling and display preferences never enter this suffix.
  String get cacheSuffix => maxAnalysisSide == 1600 && detectionThreshold == .45 &&
      recognitionThreshold == .35 && unclipRatio == 1.4 ? '' :
      ':analysis-v1:${jsonEncode([maxAnalysisSide, detectionThreshold, recognitionThreshold, unclipRatio])}';

  Map<String, Object?> toSettings() => {
    'ocrMaxAnalysisSide': maxAnalysisSide,
    'ocrDetectionThreshold': detectionThreshold,
    'ocrRecognitionThreshold': recognitionThreshold,
    'ocrUnclipRatio': unclipRatio,
  };
}

enum ComicTranslationQuality {
  fast, balanced, precise, custom;

  Map<String, Object?> get settings => switch (this) {
    fast => {
      ...const ComicOcrParameters(maxAnalysisSide: 1024).toSettings(),
      'translationPrefetchPages': 2, 'translationCachePrefetchPages': 4, 'contextPages': 0,
    },
    balanced => {
      ...const ComicOcrParameters().toSettings(),
      'translationPrefetchPages': 4, 'translationCachePrefetchPages': 4, 'contextPages': 2,
    },
    precise => {
      ...const ComicOcrParameters(maxAnalysisSide: 2240).toSettings(),
      'translationPrefetchPages': 6, 'translationCachePrefetchPages': 6, 'contextPages': 4,
    },
    custom => const {},
  };
}

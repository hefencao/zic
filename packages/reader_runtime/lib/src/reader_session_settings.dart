import 'dart:math' as math;

import 'package:domain/domain.dart';
import 'package:flutter/foundation.dart';
import 'package:reader/reader.dart';

enum ReaderPagedDirectionPreference {
  ltr,
  rtl,
  source,
}

enum ReaderSystemStatusBarMode {
  show,
  hide,
  followControls,
}

enum ReaderGestureAction {
  defaultBehavior,
  previousPage,
  nextPage,
  previousChapter,
  nextChapter,
}

const List<ReaderGestureAction> readerDefaultGestureZones =
    <ReaderGestureAction>[
  ReaderGestureAction.defaultBehavior,
  ReaderGestureAction.defaultBehavior,
  ReaderGestureAction.defaultBehavior,
  ReaderGestureAction.defaultBehavior,
  ReaderGestureAction.defaultBehavior,
  ReaderGestureAction.defaultBehavior,
  ReaderGestureAction.defaultBehavior,
  ReaderGestureAction.defaultBehavior,
  ReaderGestureAction.defaultBehavior,
];

@immutable
final class ReaderGestureGridLayout {
  const ReaderGestureGridLayout({
    this.firstColumnEnd = 1 / 3,
    this.secondColumnEnd = 2 / 3,
    this.firstRowEnd = 1 / 3,
    this.secondRowEnd = 2 / 3,
  });

  static const double minimumCellFraction = 0.12;

  final double firstColumnEnd;
  final double secondColumnEnd;
  final double firstRowEnd;
  final double secondRowEnd;

  static bool validBreaks(double first, double second) =>
      first.isFinite &&
      second.isFinite &&
      first >= minimumCellFraction &&
      second <= 1 - minimumCellFraction &&
      second - first >= minimumCellFraction;

  ReaderGestureGridLayout moveColumn(int divider, double normalized) {
    if (divider == 0) {
      return copyWith(
        firstColumnEnd: normalized.clamp(
          minimumCellFraction,
          secondColumnEnd - minimumCellFraction,
        ).toDouble(),
      );
    }
    return copyWith(
      secondColumnEnd: normalized.clamp(
        firstColumnEnd + minimumCellFraction,
        1 - minimumCellFraction,
      ).toDouble(),
    );
  }

  ReaderGestureGridLayout moveRow(int divider, double normalized) {
    if (divider == 0) {
      return copyWith(
        firstRowEnd: normalized.clamp(
          minimumCellFraction,
          secondRowEnd - minimumCellFraction,
        ).toDouble(),
      );
    }
    return copyWith(
      secondRowEnd: normalized.clamp(
        firstRowEnd + minimumCellFraction,
        1 - minimumCellFraction,
      ).toDouble(),
    );
  }

  ReaderGestureGridLayout copyWith({
    double? firstColumnEnd,
    double? secondColumnEnd,
    double? firstRowEnd,
    double? secondRowEnd,
  }) =>
      ReaderGestureGridLayout(
        firstColumnEnd: firstColumnEnd ?? this.firstColumnEnd,
        secondColumnEnd: secondColumnEnd ?? this.secondColumnEnd,
        firstRowEnd: firstRowEnd ?? this.firstRowEnd,
        secondRowEnd: secondRowEnd ?? this.secondRowEnd,
      );

  int columnFor(double fraction) =>
      fraction < firstColumnEnd ? 0 : fraction < secondColumnEnd ? 1 : 2;

  int rowFor(double fraction) =>
      fraction < firstRowEnd ? 0 : fraction < secondRowEnd ? 1 : 2;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReaderGestureGridLayout &&
          firstColumnEnd == other.firstColumnEnd &&
          secondColumnEnd == other.secondColumnEnd &&
          firstRowEnd == other.firstRowEnd &&
          secondRowEnd == other.secondRowEnd;

  @override
  int get hashCode => Object.hash(
        firstColumnEnd,
        secondColumnEnd,
        firstRowEnd,
        secondRowEnd,
      );
}

const ReaderGestureGridLayout readerDefaultGestureGridLayout =
    ReaderGestureGridLayout();

/// User-facing behavior that is intentionally scoped to one Reader layout
/// mode. Paged and continuous reading keep separate instances so changing a
/// gesture/zoom choice in one mode cannot silently rewrite the other.
@immutable
final class ReaderModeSettings {
  const ReaderModeSettings({
    this.crossChapterReading = false,
    this.zoomStages = ReaderSessionSettings.defaultZoomStages,
    this.longPressZoomEnabled = true,
    this.longPressZoomScale = 2.0,
    this.longPressZoomRestoreOnRelease = true,
    this.longPressZoomMoveMode = ReaderLongPressMoveMode.drag,
    this.longPressZoomPanRatio = 1.0,
    this.longPressZoomLimitToViewport = true,
    this.doubleTapZoomOrigin = ReaderDoubleTapZoomOrigin.center,
    this.zoomDecodeBoost = true,
    this.singleTapPageAnimation = true,
    this.singleTapZones = readerDefaultGestureZones,
    this.singleTapGridLayout = readerDefaultGestureGridLayout,
  });

  const ReaderModeSettings.continuousDefaults()
      : crossChapterReading = false,
        zoomStages = ReaderSessionSettings.defaultZoomStages,
        longPressZoomEnabled = false,
        longPressZoomScale = 2.0,
        longPressZoomRestoreOnRelease = false,
        longPressZoomMoveMode = ReaderLongPressMoveMode.drag,
        longPressZoomPanRatio = 1.0,
        longPressZoomLimitToViewport = true,
        doubleTapZoomOrigin = ReaderDoubleTapZoomOrigin.center,
        zoomDecodeBoost = true,
        singleTapPageAnimation = true,
        singleTapZones = readerDefaultGestureZones,
        singleTapGridLayout = readerDefaultGestureGridLayout;

  final bool crossChapterReading;
  final List<double> zoomStages;
  final bool longPressZoomEnabled;
  final double longPressZoomScale;
  final bool longPressZoomRestoreOnRelease;
  final ReaderLongPressMoveMode longPressZoomMoveMode;
  final double longPressZoomPanRatio;
  final bool longPressZoomLimitToViewport;
  final ReaderDoubleTapZoomOrigin doubleTapZoomOrigin;
  final bool zoomDecodeBoost;

  /// Single-tap action map. Double-tap and long-press keep their existing
  /// gesture owners and may gain independent region maps later; they must not
  /// reuse this list implicitly.
  final bool singleTapPageAnimation;
  final List<ReaderGestureAction> singleTapZones;
  final ReaderGestureGridLayout singleTapGridLayout;

  double get zoomStageFirst =>
      zoomStages.isNotEmpty ? _clampReaderStage(zoomStages[0], 1.1) : 1.5;
  double get zoomStageSecond => zoomStages.length > 1
      ? _clampReaderStage(zoomStages[1], zoomStageFirst)
      : math.max(2.0, zoomStageFirst * 2);
  double get effectiveLongPressZoomScale => longPressZoomScale.isFinite
      ? longPressZoomScale.clamp(1.1, 8).toDouble()
      : 2.0;

  ReaderModeSettings copyWith({
    bool? crossChapterReading,
    List<double>? zoomStages,
    bool? longPressZoomEnabled,
    double? longPressZoomScale,
    bool? longPressZoomRestoreOnRelease,
    ReaderLongPressMoveMode? longPressZoomMoveMode,
    double? longPressZoomPanRatio,
    bool? longPressZoomLimitToViewport,
    ReaderDoubleTapZoomOrigin? doubleTapZoomOrigin,
    bool? zoomDecodeBoost,
    bool? singleTapPageAnimation,
    List<ReaderGestureAction>? singleTapZones,
    ReaderGestureGridLayout? singleTapGridLayout,
  }) =>
      ReaderModeSettings(
        crossChapterReading:
            crossChapterReading ?? this.crossChapterReading,
        zoomStages: zoomStages ?? this.zoomStages,
        longPressZoomEnabled:
            longPressZoomEnabled ?? this.longPressZoomEnabled,
        longPressZoomScale: longPressZoomScale ?? this.longPressZoomScale,
        longPressZoomRestoreOnRelease: longPressZoomRestoreOnRelease ??
            this.longPressZoomRestoreOnRelease,
        longPressZoomMoveMode:
            longPressZoomMoveMode ?? this.longPressZoomMoveMode,
        longPressZoomPanRatio:
            longPressZoomPanRatio ?? this.longPressZoomPanRatio,
        longPressZoomLimitToViewport: longPressZoomLimitToViewport ??
            this.longPressZoomLimitToViewport,
        doubleTapZoomOrigin:
            doubleTapZoomOrigin ?? this.doubleTapZoomOrigin,
        zoomDecodeBoost: zoomDecodeBoost ?? this.zoomDecodeBoost,
        singleTapPageAnimation:
            singleTapPageAnimation ?? this.singleTapPageAnimation,
        singleTapZones: singleTapZones ?? this.singleTapZones,
        singleTapGridLayout:
            singleTapGridLayout ?? this.singleTapGridLayout,
      );

  ReaderGestureAction singleTapActionAt(int index) =>
      index >= 0 && index < singleTapZones.length
          ? singleTapZones[index]
          : ReaderGestureAction.defaultBehavior;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReaderModeSettings &&
          crossChapterReading == other.crossChapterReading &&
          _sameReaderStages(zoomStages, other.zoomStages) &&
          longPressZoomEnabled == other.longPressZoomEnabled &&
          longPressZoomScale == other.longPressZoomScale &&
          longPressZoomRestoreOnRelease ==
              other.longPressZoomRestoreOnRelease &&
          longPressZoomMoveMode == other.longPressZoomMoveMode &&
          longPressZoomPanRatio == other.longPressZoomPanRatio &&
          longPressZoomLimitToViewport ==
              other.longPressZoomLimitToViewport &&
          doubleTapZoomOrigin == other.doubleTapZoomOrigin &&
          zoomDecodeBoost == other.zoomDecodeBoost &&
          singleTapPageAnimation == other.singleTapPageAnimation &&
          _sameGestureZones(singleTapZones, other.singleTapZones) &&
          singleTapGridLayout == other.singleTapGridLayout;

  @override
  int get hashCode => Object.hashAll(<Object?>[
        crossChapterReading,
        Object.hashAll(zoomStages),
        longPressZoomEnabled,
        longPressZoomScale,
        longPressZoomRestoreOnRelease,
        longPressZoomMoveMode,
        longPressZoomPanRatio,
        longPressZoomLimitToViewport,
        doubleTapZoomOrigin,
        zoomDecodeBoost,
        singleTapPageAnimation,
        Object.hashAll(singleTapZones),
        singleTapGridLayout,
      ]);
}

@immutable
final class ReaderSessionSettings {
  const ReaderSessionSettings({
    this.comicSpecificEnabled = false,
    this.directionOverride,
    this.verticalStitchOverride,
    this.fallbackVerticalStitch = false,
    this.pagedDirectionPreference = ReaderPagedDirectionPreference.ltr,
    this.globalAdaptiveEnabled = false,
    this.comicAdaptiveEnabled = true,
    this.sourceWebtoonConfidence = 0.5,
    this.adaptiveProfile,
    this.paged = const ReaderModeSettings(),
    this.continuous = const ReaderModeSettings.continuousDefaults(),
    this.longPressZoomOverride,
    this.systemStatusBarMode = ReaderSystemStatusBarMode.show,
    this.invertPageOrderOverride,
  });

  static const Object _unset = Object();
  static const List<double> defaultZoomStages = <double>[1.5, 2.0];

  final bool comicSpecificEnabled;
  final ReadingDirection? directionOverride;
  final bool? verticalStitchOverride;
  final bool fallbackVerticalStitch;
  final ReaderPagedDirectionPreference pagedDirectionPreference;
  final bool globalAdaptiveEnabled;
  final bool comicAdaptiveEnabled;

  /// Source-level probability-like prior: 0 = strongly paged, 0.5 = neutral,
  /// 1 = strongly webtoon. This is evidence, not a manual direction override.
  final double sourceWebtoonConfidence;
  final AdaptiveReaderProfile? adaptiveProfile;
  final bool? invertPageOrderOverride;

  /// Global mode-scoped presentation/gesture choices.
  ///
  /// They are read-only in Reader. App preferences own persistence; Pipeline
  /// owns prefetch. In particular [ReaderModeSettings.crossChapterReading]
  /// only controls whether Reader UI may traverse a chapter boundary.
  final ReaderModeSettings paged;
  final ReaderModeSettings continuous;

  /// Per-comic tri-state remains a deliberate explicit override across modes.
  /// Null leaves the behavior to adaptive policy and then the active mode
  /// profile.
  final bool? longPressZoomOverride;

  /// Reader status-bar visibility is UI-global rather than layout-specific.
  final ReaderSystemStatusBarMode systemStatusBarMode;

  bool get effectiveInvertPageOrder =>
      comicSpecificEnabled && (invertPageOrderOverride ?? false);

  bool get effectiveVerticalStitch => comicSpecificEnabled
      ? verticalStitchOverride ?? fallbackVerticalStitch
      : fallbackVerticalStitch;
  bool get effectiveAdaptiveEnabled =>
      globalAdaptiveEnabled && comicAdaptiveEnabled;

  ReaderModeSettings modeSettingsFor(ReaderMode mode) =>
      mode == ReaderMode.continuous ? continuous : paged;

  ReaderModeSettings modeSettingsForDirection(ReadingDirection direction) =>
      direction == ReadingDirection.vertical ? continuous : paged;

  ReadingDirection resolvePagedDirection(ReadingDirection sourceDirection) =>
      switch (pagedDirectionPreference) {
        ReaderPagedDirectionPreference.ltr => ReadingDirection.ltr,
        ReaderPagedDirectionPreference.rtl => ReadingDirection.rtl,
        ReaderPagedDirectionPreference.source => sourceDirection,
      };

  bool resolveSystemStatusBarVisible(bool controlsVisible) =>
      switch (systemStatusBarMode) {
        ReaderSystemStatusBarMode.show => true,
        ReaderSystemStatusBarMode.hide => false,
        ReaderSystemStatusBarMode.followControls => controlsVisible,
      };

  bool effectiveLongPressZoomFor(ReadingDirection direction) {
    if (comicSpecificEnabled && longPressZoomOverride != null) {
      return longPressZoomOverride!;
    }
    final adaptive = adaptiveProfile;
    if (effectiveAdaptiveEnabled &&
        adaptive != null &&
        adaptive.isCurrent &&
        adaptive.confidence >= AdaptiveReaderProfile.applyConfidence) {
      // Adaptive type is stronger than the global baseline but remains
      // independent from manual direction overrides.
      return adaptive.direction != ReadingDirection.vertical;
    }
    return modeSettingsForDirection(direction).longPressZoomEnabled;
  }

  ReaderSessionSettings copyWith({
    bool? comicSpecificEnabled,
    Object? directionOverride = _unset,
    Object? verticalStitchOverride = _unset,
    bool? fallbackVerticalStitch,
    ReaderPagedDirectionPreference? pagedDirectionPreference,
    bool? globalAdaptiveEnabled,
    bool? comicAdaptiveEnabled,
    double? sourceWebtoonConfidence,
    Object? adaptiveProfile = _unset,
    ReaderModeSettings? paged,
    ReaderModeSettings? continuous,
    Object? longPressZoomOverride = _unset,
    ReaderSystemStatusBarMode? systemStatusBarMode,
    Object? invertPageOrderOverride = _unset,
  }) =>
      ReaderSessionSettings(
        comicSpecificEnabled:
            comicSpecificEnabled ?? this.comicSpecificEnabled,
        directionOverride: identical(directionOverride, _unset)
            ? this.directionOverride
            : directionOverride as ReadingDirection?,
        verticalStitchOverride: identical(verticalStitchOverride, _unset)
            ? this.verticalStitchOverride
            : verticalStitchOverride as bool?,
        fallbackVerticalStitch:
            fallbackVerticalStitch ?? this.fallbackVerticalStitch,
        pagedDirectionPreference:
            pagedDirectionPreference ?? this.pagedDirectionPreference,
        globalAdaptiveEnabled:
            globalAdaptiveEnabled ?? this.globalAdaptiveEnabled,
        comicAdaptiveEnabled:
            comicAdaptiveEnabled ?? this.comicAdaptiveEnabled,
        sourceWebtoonConfidence:
            sourceWebtoonConfidence ?? this.sourceWebtoonConfidence,
        adaptiveProfile: identical(adaptiveProfile, _unset)
            ? this.adaptiveProfile
            : adaptiveProfile as AdaptiveReaderProfile?,
        paged: paged ?? this.paged,
        continuous: continuous ?? this.continuous,
        longPressZoomOverride: identical(longPressZoomOverride, _unset)
            ? this.longPressZoomOverride
            : longPressZoomOverride as bool?,
        systemStatusBarMode:
            systemStatusBarMode ?? this.systemStatusBarMode,
        invertPageOrderOverride: identical(invertPageOrderOverride, _unset)
            ? this.invertPageOrderOverride
            : invertPageOrderOverride as bool?,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReaderSessionSettings &&
          comicSpecificEnabled == other.comicSpecificEnabled &&
          directionOverride == other.directionOverride &&
          verticalStitchOverride == other.verticalStitchOverride &&
          fallbackVerticalStitch == other.fallbackVerticalStitch &&
          pagedDirectionPreference == other.pagedDirectionPreference &&
          globalAdaptiveEnabled == other.globalAdaptiveEnabled &&
          comicAdaptiveEnabled == other.comicAdaptiveEnabled &&
          sourceWebtoonConfidence == other.sourceWebtoonConfidence &&
          adaptiveProfile == other.adaptiveProfile &&
          paged == other.paged &&
          continuous == other.continuous &&
          longPressZoomOverride == other.longPressZoomOverride &&
          systemStatusBarMode == other.systemStatusBarMode &&
          invertPageOrderOverride == other.invertPageOrderOverride;

  @override
  int get hashCode => Object.hashAll(<Object?>[
        comicSpecificEnabled,
        directionOverride,
        verticalStitchOverride,
        fallbackVerticalStitch,
        pagedDirectionPreference,
        globalAdaptiveEnabled,
        comicAdaptiveEnabled,
        sourceWebtoonConfidence,
        adaptiveProfile,
        paged,
        continuous,
        longPressZoomOverride,
        systemStatusBarMode,
        invertPageOrderOverride,
      ]);
}

bool _sameReaderStages(List<double> a, List<double> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

bool _sameGestureZones(List<ReaderGestureAction> a, List<ReaderGestureAction> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

double _clampReaderStage(double value, double lowerBound) {
  if (!value.isFinite) return lowerBound <= 1 ? 2.0 : lowerBound;
  return value.clamp(math.max(1.1, lowerBound), 8.0).toDouble();
}

@immutable
final class AdaptiveReaderMetadata {
  AdaptiveReaderMetadata({
    required this.sourceKey,
    required this.comicId,
    required String title,
    Iterable<String> authors = const <String>[],
    Iterable<String> tags = const <String>[],
    this.sourceName = '',
    this.sourceUrl = '',
    this.sourceType,
  })  : title = title.toLowerCase(),
        authors = List<String>.unmodifiable(
          authors
              .map((value) => value.trim().toLowerCase())
              .where((value) => value.isNotEmpty),
        ),
        tags = List<String>.unmodifiable(
          (tags
                  .map((value) => value.trim().toLowerCase())
                  .where((value) => value.isNotEmpty)
                  .toList(growable: false)
                ..sort()),
        );

  final String sourceKey;
  final String comicId;
  final String title;
  final List<String> authors;
  final List<String> tags;
  final String sourceName;
  final String sourceUrl;

  /// Explicit adaptive source metadata such as `animated`, `vertical` or
  /// `paged`. The ordinary chapter [ReadingDirection] is not this field.
  final String? sourceType;

  String get sourceIdentity =>
      '$sourceKey $sourceName $sourceUrl'.toLowerCase();

  int get fingerprint => _stableFingerprint(
        '$title\u0000${authors.join('\u0000')}\u0000'
        '${tags.join('\u0000')}\u0000$sourceIdentity\u0000'
        '${sourceType?.toLowerCase() ?? ''}',
      );
}

@immutable
final class AdaptiveReaderProfile {
  const AdaptiveReaderProfile({
    required this.direction,
    required this.confidence,
    required this.basis,
    this.animated = false,
    this.samples = 0,
    this.metadataFingerprint = 0,
    this.modelVersion = currentModelVersion,
  });

  static const int currentModelVersion = 8;
  static const double applyConfidence = 0.60;
  static const double stopConfidence = 0.80;

  final ReadingDirection direction;
  final double confidence;
  final String basis;
  final bool animated;
  final int samples;
  final int metadataFingerprint;
  final int modelVersion;

  bool get isCurrent => modelVersion == currentModelVersion;
  bool get isTerminal => confidence >= stopConfidence;

  Map<String, Object?> toJson() => <String, Object?>{
        'direction': direction.name,
        'confidence': confidence,
        'basis': basis,
        'animated': animated,
        'samples': samples,
        'metadataFingerprint': metadataFingerprint,
        'modelVersion': modelVersion,
      };

  factory AdaptiveReaderProfile.fromJson(Map<String, Object?> json) {
    final confidence = (json['confidence'] as num?)?.toDouble();
    final samples = json['samples'];
    final version = json['modelVersion'];
    final fingerprint = json['metadataFingerprint'];
    return AdaptiveReaderProfile(
      direction: ReadingDirection.values.byName(json['direction']! as String),
      confidence: confidence != null && confidence.isFinite
          ? confidence.clamp(0.0, 1.0).toDouble()
          : 0,
      basis: (json['basis'] as String?) ?? 'unknown',
      animated: json['animated'] == true,
      samples: samples is int && samples >= 0 ? samples : 0,
      metadataFingerprint:
          fingerprint is int && fingerprint >= 0 ? fingerprint : 0,
      modelVersion: version is int ? version : 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AdaptiveReaderProfile &&
          direction == other.direction &&
          confidence == other.confidence &&
          basis == other.basis &&
          animated == other.animated &&
          samples == other.samples &&
          metadataFingerprint == other.metadataFingerprint &&
          modelVersion == other.modelVersion;

  @override
  int get hashCode => Object.hash(
        direction,
        confidence,
        basis,
        animated,
        samples,
        metadataFingerprint,
        modelVersion,
      );
}

/// Per-comic adaptive layout classifier based on the independently designed
/// VibeVenera policy. Source direction remains a fallback, not classification
/// evidence; page geometry and decoded animation observations own the profile.
final class AdaptiveReaderClassifier {
  AdaptiveReaderClassifier(
    this.chapter, {
    this.metadata,
    double sourceWebtoonConfidence = 0.5,
  }) : sourceWebtoonConfidence =
            sourceWebtoonConfidence.clamp(0.0, 1.0).toDouble() {
    _metadataFingerprint = this.sourceWebtoonConfidence == 0.5
        ? metadata?.fingerprint ?? 0
        : _stableFingerprint(
            '${metadata?.fingerprint ?? 0}\u0000source-webtoon-confidence:'
            '${this.sourceWebtoonConfidence.toStringAsFixed(3)}',
          );
    for (final page in chapter.pages) {
      final width = page.width;
      final height = page.height;
      if (width != null && height != null) {
        _recordDimensions(page, width, height);
      }
    }
  }

  final ChapterManifest chapter;
  final AdaptiveReaderMetadata? metadata;
  final double sourceWebtoonConfidence;
  late final int _metadataFingerprint;
  final Map<String, ({int width, int height})> _samples =
      <String, ({int width, int height})>{};
  final Set<String> _animatedSamples = <String>{};
  bool _geometryDecisionComplete = false;

  int get metadataFingerprint => _metadataFingerprint;

  AdaptiveReaderProfile? classifyMetadata() {
    final value = metadata;
    if (value == null) return _sourceWebtoonProfile();
    var animatedTag = _match(value.tags, const <String>[
      'webp动图',
      'webp 動圖',
      'webp動畫',
      'webp 動畫',
      '动态webp',
      '動態webp',
      'animated webp',
      'animated',
      '动图',
      '動圖',
      '动态图',
      '動態圖',
    ]);
    animatedTag ??= _exactOrNamespacedTag(value.tags, 'gif');
    if (animatedTag != null) {
      return _metadataProfile(
        direction: _pagedDirection,
        confidence: 0.995,
        basis: 'tag:$animatedTag',
        animated: true,
      );
    }
    final animatedTitle = _match(<String>[value.title], const <String>[
      'webp动图',
      'webp 動圖',
      'webp動畫',
      'webp 動畫',
      '动态webp',
      '動態webp',
      'animated webp',
      '[animated]',
      '【动图】',
      '【動圖】',
      '[动图]',
      '[動圖]',
    ]);
    if (animatedTitle != null) {
      return _metadataProfile(
        direction: _pagedDirection,
        confidence: 0.98,
        basis: 'title:$animatedTitle',
        animated: true,
      );
    }

    final verticalTag = _match(value.tags, const <String>[
      'webtoon',
      'manhwa',
      '韩漫',
      '韓漫',
      '条漫',
      '條漫',
      '长条漫',
      '長條漫',
      '长条漫画',
      '長條漫畫',
      'long strip',
      'vertical comic',
      'vertical scroll',
      'scroll comic',
    ]);
    final pagedTag = _match(value.tags, const <String>[
      '日漫',
      '日本漫画',
      '日本漫畫',
      'japanese manga',
    ]);
    if (verticalTag != null && pagedTag == null) {
      return _metadataProfile(
        direction: ReadingDirection.vertical,
        confidence: 0.97,
        basis: 'tag:$verticalTag',
      );
    }
    if (pagedTag != null && verticalTag == null) {
      return _metadataProfile(
        direction: _pagedDirection,
        confidence: 0.97,
        basis: 'tag:$pagedTag',
      );
    }

    // A sufficiently strong user source prior can correct a provider-level
    // adaptive default, while comic-specific tags above still win.
    final sourcePrior = _sourceWebtoonProfile();
    if (sourcePrior != null) return sourcePrior;

    final configured = _configuredDirection(value.sourceType);
    if (configured != null) {
      return _metadataProfile(
        direction: configured.$1,
        confidence: 0.99,
        basis: 'source:configured',
        animated: configured.$2,
      );
    }
    final verticalTitle = _match(<String>[value.title], const <String>[
      'webtoon',
      'manhwa',
      '韩漫',
      '韓漫',
      '条漫',
      '條漫',
      '长条漫',
      '長條漫',
      'long strip',
      'vertical comic',
      'vertical scroll',
      'scroll comic',
    ]);
    if (verticalTitle != null) {
      return _metadataProfile(
        direction: ReadingDirection.vertical,
        confidence: 0.94,
        basis: 'title:$verticalTitle',
      );
    }
    final pagedTitle = _match(<String>[value.title], const <String>[
      '日漫',
      '日本漫画',
      '日本漫畫',
    ]);
    if (pagedTitle != null) {
      return _metadataProfile(
        direction: _pagedDirection,
        confidence: 0.94,
        basis: 'title:$pagedTitle',
      );
    }
    final verticalSource = _match(
      <String>[value.sourceIdentity],
      const <String>[
        'webtoons.com',
        'webtoon',
        'lezhin',
        'bomtoon',
        'toomics',
        'toptoon',
      ],
    );
    if (verticalSource != null) {
      return _metadataProfile(
        direction: ReadingDirection.vertical,
        confidence: 0.95,
        basis: 'source:$verticalSource',
      );
    }
    final pagedSource = _match(
      <String>[value.sourceIdentity],
      const <String>['nhentai'],
    );
    if (pagedSource != null) {
      return _metadataProfile(
        direction: _pagedDirection,
        confidence: 0.95,
        basis: 'source:$pagedSource',
      );
    }
    final category = _category(value.tags);
    if (category == 'manga') {
      return _metadataProfile(
        direction: ReadingDirection.vertical,
        confidence: 0.72,
        basis: 'category:manga',
      );
    }
    if (const <String>{
      'comic',
      'doujinshi',
      'doujin',
      'artist cg',
      'game cg',
      'cg',
      'misc',
      'image set',
    }.contains(category)) {
      return _metadataProfile(
        direction: _pagedDirection,
        confidence:
            category == 'comic' || category == 'doujinshi' ? 0.76 : 0.68,
        basis: 'category:$category',
      );
    }
    final originalWork = _tagNamespace(
      value.tags,
      const <String>{'原作', '原作名', 'parody', 'original work'},
    );
    if (originalWork != null) {
      return _metadataProfile(
        direction: _pagedDirection,
        confidence: 0.70,
        basis: 'tag-namespace:$originalWork',
      );
    }
    final language = _metadataLanguage(value);
    if (language == 'ko') {
      return _metadataProfile(
        direction: ReadingDirection.vertical,
        confidence: 0.86,
        basis: 'language:korean',
      );
    }
    if (language == 'ja') {
      return _metadataProfile(
        direction: _pagedDirection,
        confidence: 0.86,
        basis: 'language:japanese',
      );
    }
    return null;
  }

  AdaptiveReaderProfile? classifyManifest() {
    final metadataProfile = classifyMetadata();
    if (metadataProfile != null) return metadataProfile;
    final animated = _classifyAnimated('animated-pages');
    return animated ?? _takeGeometryDecision();
  }

  AdaptiveReaderProfile? observeDimensions(
    PageAsset page,
    int width,
    int height,
  ) {
    if (width <= 0 || height <= 0 || _geometryDecisionComplete) return null;
    final previous = _samples[page.assetKey];
    if (previous?.width == width && previous?.height == height) return null;
    _recordDimensions(page, width, height);
    return _takeGeometryDecision();
  }

  AdaptiveReaderProfile? observeAnimated(PageAsset page) {
    if (_isCover(page)) return null;
    if (!_animatedSamples.add(page.assetKey)) return null;
    return _classifyAnimated('decoded-animation');
  }

  void _recordDimensions(PageAsset page, int width, int height) {
    if (width <= 0 || height <= 0) return;
    if (!_samples.containsKey(page.assetKey) &&
        _samples.length >= _geometrySampleTarget) {
      return;
    }
    _samples[page.assetKey] = (width: width, height: height);
  }

  bool _isCover(PageAsset page) => chapter.pages.length > 2 && page.index == 0;

  static const int _requiredAnimationSamples = 2;
  static const int _minimumGeometrySamples = 2;
  static const int _geometrySampleLimit = 3;
  static const double _ambiguousLandscapeRatio = 0.65;
  static const double _pagedPortraitRatio = 1.20;

  int get _geometrySampleTarget =>
      math.min(_geometrySampleLimit, chapter.pages.length).toInt();

  AdaptiveReaderProfile? _classifyAnimated(String basis) {
    if (_animatedSamples.length < _requiredAnimationSamples) return null;
    return AdaptiveReaderProfile(
      direction: chapter.readingDirection == ReadingDirection.rtl
          ? ReadingDirection.rtl
          : ReadingDirection.ltr,
      confidence: 1,
      basis: basis,
      animated: true,
      samples: _animatedSamples.length,
      metadataFingerprint: _metadataFingerprint,
    );
  }

  AdaptiveReaderProfile? _takeGeometryDecision() {
    final target = _geometrySampleTarget;
    if (_geometryDecisionComplete ||
        target < _minimumGeometrySamples ||
        _samples.length < target) {
      return null;
    }
    _geometryDecisionComplete = true;
    return _classifyGeometry();
  }

  AdaptiveReaderProfile? _classifyGeometry() {
    var vertical = 0.0;
    var paged = 0.0;
    for (final sample in _samples.values) {
      final ratio = sample.height / sample.width;
      if (ratio >= 3) {
        vertical += 4;
      } else if (ratio >= 2.2) {
        vertical += 2.4;
      } else if (ratio >= 1.9) {
        vertical += 0.8;
        paged += 0.7;
      } else if (ratio >= _pagedPortraitRatio) {
        final start = math.log(_pagedPortraitRatio) / math.ln2;
        final end = math.log(1.9) / math.ln2;
        final distance = math.log(ratio) / math.ln2;
        final pagedDistance =
            ((distance - start) / (end - start)).clamp(0.0, 1.0).toDouble();
        paged += 1.5 * pagedDistance;
      } else if (ratio <= _ambiguousLandscapeRatio) {
        final start =
            (math.log(_ambiguousLandscapeRatio).abs() / math.ln2);
        final distance =
            (math.log(ratio).abs() / math.ln2).clamp(0.0, 1.0).toDouble();
        final pagedDistance =
            ((distance - start) / (1 - start)).clamp(0.0, 1.0).toDouble();
        paged += 1.5 * pagedDistance;
      } else {
        // Ratios between a clearly wide page and an ordinary portrait page
        // are intentionally neutral. Webtoon sources often cut one strip
        // into 720x500/720x700-like transport slices, and treating every
        // non-square shape as a page recreates the original false positive.
      }
    }
    // Geometry is a one-shot sample, not an online vote counter. Cap its
    // aggregate strength at three representative pages even when six samples
    // are used to estimate the shape distribution.
    final geometryBudget = math.min(3, _samples.length).toDouble();
    final geometryScale = geometryBudget / _samples.length;
    vertical *= geometryScale;
    paged *= geometryScale;
    final tags = metadata?.tags ?? const <String>[];
    final verticalMetadata = _tagWeight(
      tags,
      const <String>[
        'webtoon',
        'manhwa',
        'korean',
        'korea',
        '韩国',
        '韓國',
        '韩漫',
        '韓漫',
        '条漫',
        '條漫',
        '长条',
        '長條',
        'long strip',
        'vertical comic',
        'vertical scroll',
        'scroll comic',
        'category:manga',
        'type:manga',
        '分类:manga',
        '分類:manga',
      ],
      1.8,
    );
    vertical += verticalMetadata;
    paged += _tagWeight(
      tags,
      const <String>[
        'comic',
        'doujin',
        'doujinshi',
        '日漫',
        '同人',
        'tankoubon',
        '原作:',
        'parody:',
        'artist cg',
        'game cg',
        'misc',
        'image set',
      ],
      1.2,
    );
    final sourceBias = _sourceWebtoonBias;
    vertical += sourceBias * 1.5;
    paged -= sourceBias * 1.5;
    return _scoredLayoutProfile(
      vertical: vertical,
      paged: paged,
      basis: 'page-geometry',
      samples: _samples.length,
    );
  }

  AdaptiveReaderProfile? _sourceWebtoonProfile() {
    final sourceBias = _sourceWebtoonBias;
    if (sourceBias == 0) return null;
    return _scoredLayoutProfile(
      vertical: sourceBias * 1.5,
      paged: -sourceBias * 1.5,
      basis: 'source:webtoon-confidence',
    );
  }

  double get _sourceWebtoonBias => sourceWebtoonConfidence * 2 - 1;

  AdaptiveReaderProfile? _scoredLayoutProfile({
    required double vertical,
    required double paged,
    required String basis,
    int samples = 0,
  }) {
    final mixed = math.min(vertical, paged) + 0.4;
    final maxScore = math.max(vertical, math.max(paged, mixed));
    final confidence = 1 /
        (math.exp(vertical - maxScore) +
            math.exp(paged - maxScore) +
            math.exp(mixed - maxScore));
    if (confidence < AdaptiveReaderProfile.applyConfidence ||
        mixed >= vertical && mixed >= paged) {
      return null;
    }
    return AdaptiveReaderProfile(
      direction: vertical > paged
          ? ReadingDirection.vertical
          : _pagedDirection,
      confidence: confidence,
      basis: basis,
      samples: samples,
      metadataFingerprint: _metadataFingerprint,
    );
  }

  ReadingDirection get _pagedDirection =>
      chapter.readingDirection == ReadingDirection.rtl
          ? ReadingDirection.rtl
          : ReadingDirection.ltr;

  AdaptiveReaderProfile _metadataProfile({
    required ReadingDirection direction,
    required double confidence,
    required String basis,
    bool animated = false,
  }) =>
      AdaptiveReaderProfile(
        direction: direction,
        confidence: confidence,
        basis: basis,
        animated: animated,
        metadataFingerprint: _metadataFingerprint,
      );

  static double _tagWeight(
    List<String> tags,
    List<String> tokens,
    double weight,
  ) {
    var matches = 0;
    for (final token in tokens) {
      if (tags.any((tag) => tag.contains(token))) matches++;
    }
    return math.min(matches, 2).toDouble() * weight;
  }

  static String? _category(List<String> tags) {
    const namespaces = <String>{
      'category',
      'categories',
      'type',
      '分类',
      '分類',
      '类型',
      '類型',
    };
    const values = <String>{
      'manga',
      'comic',
      'doujinshi',
      'doujin',
      'artist cg',
      'game cg',
      'cg',
      'misc',
      'image set',
    };
    for (final tag in tags) {
      final separator = tag.indexOf(':');
      if (separator > 0 && namespaces.contains(tag.substring(0, separator))) {
        final value = tag.substring(separator + 1).trim();
        if (values.contains(value)) return value;
      }
      if (values.contains(tag)) return tag;
    }
    return null;
  }

  static String? _tagNamespace(
    List<String> tags,
    Set<String> namespaces,
  ) {
    for (final tag in tags) {
      final separator = tag.indexOf(':');
      if (separator > 0 && namespaces.contains(tag.substring(0, separator))) {
        return tag.substring(0, separator);
      }
    }
    return null;
  }

  static String? _metadataLanguage(AdaptiveReaderMetadata value) {
    if (_match(value.tags, const <String>[
          'language:korean',
          '语言:韩语',
          '語言:韓語',
          '韩语',
          '韓語',
          '한국어',
          'korean',
          '韩漫',
          '韓漫',
          'manhwa',
        ]) !=
        null) {
      return 'ko';
    }
    if (_match(value.tags, const <String>[
          'language:japanese',
          '语言:日语',
          '語言:日語',
          '日语',
          '日語',
          '日本語',
          'japanese',
          '日漫',
        ]) !=
        null) {
      return 'ja';
    }
    if (!_hasRawTag(value.tags)) return null;
    if (_match(value.tags, const <String>[
              'webtoon',
              'manhwa',
              '韩漫',
              '韓漫',
            ]) !=
            null ||
        _match(<String>[value.sourceIdentity], const <String>[
              'webtoons.com',
              'lezhin',
              'bomtoon',
              'toomics',
              'toptoon',
            ]) !=
            null) {
      return 'ko';
    }
    if (_match(value.tags, const <String>[
              'manga',
              'comic',
              'doujinshi',
              '同人',
              '日漫',
            ]) !=
            null ||
        _match(<String>[value.sourceIdentity], const <String>[
              'ehentai',
              'e-hentai',
              'nhentai',
            ]) !=
            null) {
      return 'ja';
    }
    return null;
  }

  static bool _hasRawTag(List<String> tags) => tags.any((tag) {
        final value = tag.contains(':')
            ? tag.substring(tag.indexOf(':') + 1)
            : tag;
        return value == 'raw' ||
            value == 'untranslated' ||
            tag.contains('生肉') ||
            tag.contains('未翻译') ||
            tag.contains('未翻譯');
      });

  static String? _exactOrNamespacedTag(List<String> tags, String value) {
    for (final tag in tags) {
      if (tag == value || tag.endsWith(':$value')) return tag;
    }
    return null;
  }

  static String? _match(List<String> values, List<String> tokens) {
    for (final value in values) {
      for (final token in tokens) {
        if (value.contains(token)) return token;
      }
    }
    return null;
  }

  (ReadingDirection, bool)? _configuredDirection(String? value) {
    switch (value?.toLowerCase()) {
      case 'animated':
        return (_pagedDirection, true);
      case 'vertical':
      case 'webtoon':
      case 'manhwa':
      case 'korean':
        return (ReadingDirection.vertical, false);
      case 'paged':
      case 'manga':
      case 'japanese':
        return (_pagedDirection, false);
    }
    return null;
  }
}


AdaptiveReaderProfile? classifyAdaptiveReaderLayout(
  ChapterManifest chapter, {
  AdaptiveReaderMetadata? metadata,
  double sourceWebtoonConfidence = 0.5,
}) =>
    AdaptiveReaderClassifier(
      chapter,
      metadata: metadata,
      sourceWebtoonConfidence: sourceWebtoonConfidence,
    ).classifyManifest();

int _stableFingerprint(String value) {
  var hash = 0x811c9dc5;
  for (final codeUnit in value.codeUnits) {
    hash = ((hash ^ codeUnit) * 0x01000193) & 0xffffffff;
  }
  return hash;
}

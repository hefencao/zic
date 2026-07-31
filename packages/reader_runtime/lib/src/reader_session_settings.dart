import 'dart:math' as math;

import 'package:domain/domain.dart';
import 'package:flutter/foundation.dart';

@immutable
final class ReaderSessionSettings {
  const ReaderSessionSettings({
    this.comicSpecificEnabled = false,
    this.directionOverride,
    this.verticalStitch = false,
    this.fallbackVerticalStitch = false,
    this.globalAdaptiveEnabled = false,
    this.comicAdaptiveEnabled = true,
  });

  static const Object _unset = Object();

  final bool comicSpecificEnabled;
  final ReadingDirection? directionOverride;
  final bool verticalStitch;
  final bool fallbackVerticalStitch;
  final bool globalAdaptiveEnabled;
  final bool comicAdaptiveEnabled;

  bool get effectiveVerticalStitch =>
      comicSpecificEnabled ? verticalStitch : fallbackVerticalStitch;
  bool get effectiveAdaptiveEnabled =>
      globalAdaptiveEnabled && comicAdaptiveEnabled;

  ReaderSessionSettings copyWith({
    bool? comicSpecificEnabled,
    Object? directionOverride = _unset,
    bool? verticalStitch,
    bool? fallbackVerticalStitch,
    bool? globalAdaptiveEnabled,
    bool? comicAdaptiveEnabled,
  }) =>
      ReaderSessionSettings(
        comicSpecificEnabled:
            comicSpecificEnabled ?? this.comicSpecificEnabled,
        directionOverride: identical(directionOverride, _unset)
            ? this.directionOverride
            : directionOverride as ReadingDirection?,
        verticalStitch: verticalStitch ?? this.verticalStitch,
        fallbackVerticalStitch:
            fallbackVerticalStitch ?? this.fallbackVerticalStitch,
        globalAdaptiveEnabled:
            globalAdaptiveEnabled ?? this.globalAdaptiveEnabled,
        comicAdaptiveEnabled:
            comicAdaptiveEnabled ?? this.comicAdaptiveEnabled,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReaderSessionSettings &&
          comicSpecificEnabled == other.comicSpecificEnabled &&
          directionOverride == other.directionOverride &&
          verticalStitch == other.verticalStitch &&
          fallbackVerticalStitch == other.fallbackVerticalStitch &&
          globalAdaptiveEnabled == other.globalAdaptiveEnabled &&
          comicAdaptiveEnabled == other.comicAdaptiveEnabled;

  @override
  int get hashCode => Object.hash(
        comicSpecificEnabled,
        directionOverride,
        verticalStitch,
        fallbackVerticalStitch,
        globalAdaptiveEnabled,
        comicAdaptiveEnabled,
      );
}

@immutable
final class AdaptiveReaderProfile {
  const AdaptiveReaderProfile({
    required this.direction,
    required this.confidence,
    required this.basis,
    this.animated = false,
  });

  final ReadingDirection direction;
  final double confidence;
  final String basis;
  final bool animated;
}

AdaptiveReaderProfile? classifyAdaptiveReaderLayout(ChapterManifest chapter) {
  final pages = chapter.pages;
  if (pages.isEmpty) return null;
  final animated = pages.where((page) => page.animatedHint).length;
  if (animated >= math.min(2, pages.length)) {
    return AdaptiveReaderProfile(
      direction: chapter.readingDirection == ReadingDirection.rtl
          ? ReadingDirection.rtl
          : ReadingDirection.ltr,
      confidence: 1,
      basis: 'animated-pages',
      animated: true,
    );
  }
  final ratios = <double>[
    for (final page in pages)
      if (page.width != null &&
          page.height != null &&
          page.width! > 0 &&
          page.height! > 0)
        page.height! / page.width!,
  ];
  if (ratios.length >= 2) {
    final tall = ratios.where((ratio) => ratio >= 2.4).length;
    final tallShare = tall / ratios.length;
    if (tallShare >= 0.6) {
      return AdaptiveReaderProfile(
        direction: ReadingDirection.vertical,
        confidence: (0.62 + tallShare * 0.36).clamp(0.0, 0.98).toDouble(),
        basis: 'page-geometry',
      );
    }
    if (tallShare <= 0.25) {
      return AdaptiveReaderProfile(
        direction: chapter.readingDirection == ReadingDirection.rtl
            ? ReadingDirection.rtl
            : ReadingDirection.ltr,
        confidence: (0.78 + (1 - tallShare) * 0.18).clamp(0.0, 0.96).toDouble(),
        basis: 'page-geometry',
      );
    }
  }
  if (chapter.readingDirection == ReadingDirection.vertical) {
    return const AdaptiveReaderProfile(
      direction: ReadingDirection.vertical,
      confidence: 0.9,
      basis: 'source-hint',
    );
  }
  return null;
}

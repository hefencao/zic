import 'package:domain/domain.dart';

import 'imported_library_store.dart';
import 'library_comic.dart';
import 'library_preferences.dart';

/// A conservative cross-source migration plan.
///
/// Source-specific chapter/page addresses are never copied. The plan only
/// carries whole-comic preferences and reports chapter candidates that can be
/// reconciled after the target source has supplied its own manifest.
final class ComicSourceMigrationPlan {
  ComicSourceMigrationPlan({
    required this.source,
    required this.target,
    required Iterable<ChapterMigrationMatch> chapterMatches,
  }) : chapterMatches = List<ChapterMigrationMatch>.unmodifiable(
          chapterMatches,
        );

  factory ComicSourceMigrationPlan.build({
    required LibraryComic source,
    required ComicManifest target,
  }) {
    if (source.sourceId == target.comic.sourceId) {
      throw ArgumentError('source migration requires a different source');
    }
    final available = target.chapters.toList(growable: false);
    final used = <String>{};
    final matches = <ChapterMigrationMatch>[];
    for (final entry in source.chapters) {
      final sourceChapter = entry.chapter;
      Chapter? selected;
      for (final candidate in available) {
        if (used.contains(candidate.chapterId)) {
          continue;
        }
        if (candidate.sequence == sourceChapter.sequence &&
            _normalizedText(candidate.title) ==
                _normalizedText(sourceChapter.displayName)) {
          selected = candidate;
          break;
        }
      }
      selected ??= _uniqueSequenceMatch(
        available,
        used,
        sourceChapter.sequence,
      );
      if (selected == null) {
        continue;
      }
      used.add(selected.chapterId);
      matches.add(
        ChapterMigrationMatch(
          source: entry,
          target: selected,
          confidence: _normalizedText(selected.title) ==
                  _normalizedText(sourceChapter.displayName)
              ? ChapterMigrationConfidence.exact
              : ChapterMigrationConfidence.sequenceOnly,
        ),
      );
    }
    return ComicSourceMigrationPlan(
      source: source,
      target: target,
      chapterMatches: matches,
    );
  }

  final LibraryComic source;
  final ComicManifest target;
  final List<ChapterMigrationMatch> chapterMatches;

  int get unmatchedSourceChapters =>
      source.chapters.length - chapterMatches.length;

  ComicSourceMigrationComparison comparison({int sampleLimit = 6}) =>
      ComicSourceMigrationComparison.fromPlan(this, sampleLimit: sampleLimit);

  ComicPreference migratePreference(
    ComicPreference preference, {
    required int targetCustomOrder,
  }) =>
      ComicPreference(
        sourceId: target.comic.sourceId,
        comicId: target.comic.comicId,
        sourceKind: ComicSourceKind.remote,
        inShelf: preference.inShelf,
        liked: preference.liked,
        collected: preference.collected,
        categoryIds: preference.categoryIds,
        customOrder: targetCustomOrder,
        updatedAt: DateTime.now().toUtc(),
      );

  /// Copy source preferences without erasing state that already belongs to
  /// the target source. Migration fills target state; it does not roll it
  /// back to the source snapshot.
  ComicPreference mergePreference(
    ComicPreference sourcePreference, {
    ComicPreference? existingTarget,
    required int targetCustomOrder,
    DateTime? updatedAt,
  }) {
    final migrated = migratePreference(
      sourcePreference,
      targetCustomOrder: existingTarget?.customOrder ?? targetCustomOrder,
    );
    return ComicPreference(
      sourceId: migrated.sourceId,
      comicId: migrated.comicId,
      sourceKind: ComicSourceKind.remote,
      inShelf: migrated.inShelf || (existingTarget?.inShelf ?? false),
      liked: migrated.liked || (existingTarget?.liked ?? false),
      collected: migrated.collected || (existingTarget?.collected ?? false),
      categoryIds: <String>{
        ...migrated.categoryIds,
        ...?existingTarget?.categoryIds,
      },
      customOrder: existingTarget?.customOrder ?? migrated.customOrder,
      updatedAt: (updatedAt ?? DateTime.now()).toUtc(),
    );
  }
}

enum ChapterMigrationConfidence { exact, sequenceOnly }

final class ChapterMigrationMatch {
  const ChapterMigrationMatch({
    required this.source,
    required this.target,
    required this.confidence,
  });

  final ImportedLibraryEntry source;
  final Chapter target;
  final ChapterMigrationConfidence confidence;
}

/// Read-only evidence shown before a cross-source migration is confirmed.
///
/// The comparison deliberately reports identity and uncertainty rather than
/// claiming that similarly named works are the same work. It never performs a
/// durable write and does not weaken the exact chapter verification used by
/// [ComicSourceMigrationPlan].
final class ComicSourceMigrationComparison {
  ComicSourceMigrationComparison._({
    required this.sourceIdentity,
    required this.targetIdentity,
    required this.sourceTitle,
    required this.targetTitle,
    required Iterable<String> sourceAuthors,
    required Iterable<String> targetAuthors,
    required Iterable<String> sharedAuthors,
    required this.titleMatches,
    required this.readingDirectionDiffers,
    required this.exactChapterMatches,
    required this.sequenceOnlyChapterMatches,
    required this.unmatchedSourceChapters,
    required this.unmatchedTargetChapters,
    required Iterable<ComicSourceMigrationRisk> risks,
    required Iterable<ComicSourceMigrationChapterSample> chapterSamples,
  })  : sourceAuthors = List<String>.unmodifiable(sourceAuthors),
        targetAuthors = List<String>.unmodifiable(targetAuthors),
        sharedAuthors = List<String>.unmodifiable(sharedAuthors),
        risks = List<ComicSourceMigrationRisk>.unmodifiable(risks),
        chapterSamples =
            List<ComicSourceMigrationChapterSample>.unmodifiable(
          chapterSamples,
        );

  factory ComicSourceMigrationComparison.fromPlan(
    ComicSourceMigrationPlan plan, {
    int sampleLimit = 6,
  }) {
    if (sampleLimit < 1) {
      throw ArgumentError.value(sampleLimit, 'sampleLimit', 'must be positive');
    }
    final source = plan.source;
    final target = plan.target;
    final sourceAuthorsByKey = <String, String>{
      for (final author in source.authors)
        if (_normalizedText(author).isNotEmpty) _normalizedText(author): author,
    };
    final targetAuthorsByKey = <String, String>{
      for (final author in target.comic.authors)
        if (_normalizedText(author).isNotEmpty) _normalizedText(author): author,
    };
    final sharedAuthors = <String>[
      for (final key in sourceAuthorsByKey.keys)
        if (targetAuthorsByKey.containsKey(key)) sourceAuthorsByKey[key]!,
    ];
    final exact = plan.chapterMatches
        .where((match) => match.confidence == ChapterMigrationConfidence.exact)
        .length;
    final sequenceOnly = plan.chapterMatches.length - exact;
    final usedTargetIds = <String>{
      for (final match in plan.chapterMatches) match.target.chapterId,
    };
    final unmatchedTarget = target.chapters
        .where((chapter) => !usedTargetIds.contains(chapter.chapterId))
        .length;
    final titleMatches =
        _normalizedText(source.title) == _normalizedText(target.comic.title);
    final directionDiffers =
        source.readingDirection != target.comic.readingDirection;
    final risks = <ComicSourceMigrationRisk>[
      if (!titleMatches) ComicSourceMigrationRisk.titleDiffers,
      if (source.authors.isNotEmpty &&
          target.comic.authors.isNotEmpty &&
          sharedAuthors.isEmpty)
        ComicSourceMigrationRisk.noSharedAuthors,
      if (directionDiffers) ComicSourceMigrationRisk.readingDirectionDiffers,
      if (sequenceOnly > 0) ComicSourceMigrationRisk.sequenceOnlyMatches,
      if (plan.unmatchedSourceChapters > 0)
        ComicSourceMigrationRisk.unmatchedSourceChapters,
      if (target.chapters.isEmpty)
        ComicSourceMigrationRisk.targetCatalogEmpty,
    ];

    final samples = <ComicSourceMigrationChapterSample>[];
    final sortedMatches = plan.chapterMatches.toList(growable: false)
      ..sort((left, right) {
        final confidence =
            left.confidence.index.compareTo(right.confidence.index);
        if (confidence != 0) {
          return confidence;
        }
        return left.source.chapter.sequence.compareTo(
          right.source.chapter.sequence,
        );
      });
    for (final match in sortedMatches) {
      if (samples.length >= sampleLimit) {
        break;
      }
      samples.add(
        ComicSourceMigrationChapterSample(
          sourceTitle: match.source.chapter.displayName,
          sourceSequence: match.source.chapter.sequence,
          targetTitle: match.target.title,
          targetSequence: match.target.sequence,
          confidence: match.confidence,
        ),
      );
    }
    if (samples.length < sampleLimit) {
      final matchedSourceIds = <String>{
        for (final match in plan.chapterMatches)
          match.source.chapter.chapterId,
      };
      for (final entry in source.chapters) {
        if (samples.length >= sampleLimit) {
          break;
        }
        if (matchedSourceIds.contains(entry.chapter.chapterId)) {
          continue;
        }
        samples.add(
          ComicSourceMigrationChapterSample(
            sourceTitle: entry.chapter.displayName,
            sourceSequence: entry.chapter.sequence,
          ),
        );
      }
    }

    return ComicSourceMigrationComparison._(
      sourceIdentity: '${source.sourceId}:${source.comicId}',
      targetIdentity: '${target.comic.sourceId}:${target.comic.comicId}',
      sourceTitle: source.title,
      targetTitle: target.comic.title,
      sourceAuthors: source.authors,
      targetAuthors: target.comic.authors,
      sharedAuthors: sharedAuthors,
      titleMatches: titleMatches,
      readingDirectionDiffers: directionDiffers,
      exactChapterMatches: exact,
      sequenceOnlyChapterMatches: sequenceOnly,
      unmatchedSourceChapters: plan.unmatchedSourceChapters,
      unmatchedTargetChapters: unmatchedTarget,
      risks: risks,
      chapterSamples: samples,
    );
  }

  final String sourceIdentity;
  final String targetIdentity;
  final String sourceTitle;
  final String targetTitle;
  final List<String> sourceAuthors;
  final List<String> targetAuthors;
  final List<String> sharedAuthors;
  final bool titleMatches;
  final bool readingDirectionDiffers;
  final int exactChapterMatches;
  final int sequenceOnlyChapterMatches;
  final int unmatchedSourceChapters;
  final int unmatchedTargetChapters;
  final List<ComicSourceMigrationRisk> risks;
  final List<ComicSourceMigrationChapterSample> chapterSamples;

  bool get hasRisks => risks.isNotEmpty;
}

enum ComicSourceMigrationRisk {
  titleDiffers,
  noSharedAuthors,
  readingDirectionDiffers,
  sequenceOnlyMatches,
  unmatchedSourceChapters,
  targetCatalogEmpty,
}

final class ComicSourceMigrationChapterSample {
  const ComicSourceMigrationChapterSample({
    required this.sourceTitle,
    required this.sourceSequence,
    this.targetTitle,
    this.targetSequence,
    this.confidence,
  });

  final String sourceTitle;
  final int sourceSequence;
  final String? targetTitle;
  final int? targetSequence;
  final ChapterMigrationConfidence? confidence;

  bool get matched => targetTitle != null;
}

Chapter? _uniqueSequenceMatch(
  List<Chapter> candidates,
  Set<String> used,
  int sequence,
) {
  final matches = candidates
      .where(
        (chapter) =>
            chapter.sequence == sequence && !used.contains(chapter.chapterId),
      )
      .toList(growable: false);
  return matches.length == 1 ? matches.single : null;
}

String _normalizedText(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9\u3400-\u9fff]+'), '');

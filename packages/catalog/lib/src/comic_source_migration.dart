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
            _normalizedChapterTitle(candidate.title) ==
                _normalizedChapterTitle(sourceChapter.displayName)) {
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
          confidence: _normalizedChapterTitle(selected.title) ==
                  _normalizedChapterTitle(sourceChapter.displayName)
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

String _normalizedChapterTitle(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9\u3400-\u9fff]+'), '');

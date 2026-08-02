import 'package:domain/domain.dart';

import 'imported_chapter.dart';
import 'imported_library_store.dart';
import 'saved_comic.dart';

/// Read-only comic projection over durable comic metadata and any persisted
/// chapter entries.
///
/// A comic may contain zero chapters: adding a remote work to the shelf or
/// collecting it must not implicitly persist an arbitrary chapter. Chapter
/// progress, read state and offline bytes remain chapter-owned.
final class LibraryComic {
  LibraryComic({
    required this.sourceId,
    required this.comicId,
    required this.title,
    required Iterable<String> authors,
    required Iterable<String> tags,
    required this.description,
    required this.coverSourceId,
    required this.readingDirection,
    required Iterable<ImportedLibraryEntry> chapters,
    required Iterable<Chapter> sourceChapters,
    required this.savedAt,
    required this.metadataUpdatedAt,
  })  : authors = List<String>.unmodifiable(authors),
        tags = List<String>.unmodifiable(tags),
        sourceChapters = List<Chapter>.unmodifiable(
          sourceChapters.toList(growable: false)..sort(
                (left, right) => left.sequence.compareTo(right.sequence),
              ),
        ),
        chapters = List<ImportedLibraryEntry>.unmodifiable(
          chapters.toList(growable: false)..sort(_compareChapters),
        ) {
    if (sourceId.trim().isEmpty ||
        comicId.trim().isEmpty ||
        title.trim().isEmpty) {
      throw ArgumentError('source, comic identity and title must be non-empty');
    }
    for (final entry in this.chapters) {
      if (entry.chapter.sourceId != sourceId ||
          entry.chapter.comicId != comicId) {
        throw ArgumentError.value(
          '${entry.chapter.sourceId}:${entry.chapter.comicId}',
          'chapters',
          'contains a different source or comic identity',
        );
      }
    }
  }

  factory LibraryComic.fromEntries(
    Iterable<ImportedLibraryEntry> entries, {
    SavedComicRecord? savedComic,
  }) {
    final chapters = entries.toList(growable: false);
    if (chapters.isEmpty && savedComic == null) {
      throw ArgumentError('a comic projection needs metadata or chapters');
    }
    final sourceId = savedComic?.sourceId ?? chapters.first.chapter.sourceId;
    final comicId = savedComic?.comicId ?? chapters.first.chapter.comicId;
    if (savedComic != null &&
        chapters.any(
          (entry) =>
              entry.chapter.sourceId != sourceId ||
              entry.chapter.comicId != comicId,
        )) {
      throw ArgumentError('saved metadata and chapters identify different comics');
    }

    ImportedLibraryEntry? metadataEntry;
    for (final entry in chapters) {
      final selected = metadataEntry;
      if (selected == null ||
          _metadataScore(entry.chapter) >
              _metadataScore(selected.chapter) ||
          (_metadataScore(entry.chapter) ==
                  _metadataScore(selected.chapter) &&
              entry.chapter.importedAt.isAfter(
                selected.chapter.importedAt,
              ))) {
        metadataEntry = entry;
      }
    }
    final metadata = metadataEntry?.chapter;
    final authors = <String>{...?savedComic?.authors};
    final tags = <String>{...?savedComic?.tags};
    for (final entry in chapters) {
      authors.addAll(entry.chapter.comicAuthors);
      tags.addAll(entry.chapter.comicTags);
    }
    final newestChapterAt = chapters.isEmpty
        ? null
        : chapters
            .map((entry) => entry.chapter.importedAt)
            .reduce((left, right) => right.isAfter(left) ? right : left);
    final savedAt = savedComic?.savedAt ?? newestChapterAt!;
    final metadataUpdatedAt = <DateTime>[
      if (savedComic != null) savedComic.updatedAt,
      if (newestChapterAt != null) newestChapterAt,
    ].reduce((left, right) => right.isAfter(left) ? right : left);

    return LibraryComic(
      sourceId: sourceId,
      comicId: comicId,
      title: savedComic?.title ?? metadata!.comicTitle,
      authors: authors,
      tags: tags,
      description: savedComic?.description ?? metadata?.comicDescription,
      coverSourceId: savedComic?.coverSourceId ?? metadata?.coverSourceId,
      readingDirection:
          savedComic?.readingDirection ?? metadata!.readingDirection,
      chapters: chapters,
      sourceChapters: savedComic?.chapters
              .map((chapter) => chapter.toChapter(comicId)) ??
          const <Chapter>[],
      savedAt: savedAt,
      metadataUpdatedAt: metadataUpdatedAt,
    );
  }

  factory LibraryComic.fromSaved(SavedComicRecord comic) =>
      LibraryComic.fromEntries(
        const <ImportedLibraryEntry>[],
        savedComic: comic,
      );

  final String sourceId;
  final String comicId;
  final String title;
  final List<String> authors;
  final List<String> tags;
  final String? description;
  final String? coverSourceId;
  final ReadingDirection readingDirection;
  final List<ImportedLibraryEntry> chapters;
  final List<Chapter> sourceChapters;
  final DateTime savedAt;
  final DateTime metadataUpdatedAt;

  String get identity => '$sourceId\u0000$comicId';
  bool get hasMultipleChapters => chapters.length > 1;
  bool get hasChapters => chapters.isNotEmpty;
  bool get hasSourceCatalog => sourceChapters.isNotEmpty;

  int get totalPages => chapters.fold<int>(
        0,
        (total, entry) => total + entry.chapter.pages.length,
      );

  Set<String> get sourceIds => Set<String>.unmodifiable(<String>{sourceId});

  ImportedLibraryEntry? get coverChapter {
    for (final chapter in chapters.reversed) {
      if (chapter.chapter.coverSourceId != null) {
        return chapter;
      }
    }
    return chapters.isEmpty ? null : chapters.first;
  }

  ImportedLibraryEntry? get latestChapter {
    if (chapters.isEmpty) {
      return null;
    }
    return chapters.reduce(
      (left, right) => _compareLatest(left, right) >= 0 ? left : right,
    );
  }

  ImportedLibraryEntry? get lastReadChapter {
    ImportedLibraryEntry? selected;
    for (final chapter in chapters) {
      final progress = chapter.progress;
      if (progress == null) {
        continue;
      }
      final selectedProgress = selected?.progress;
      if (selectedProgress == null ||
          progress.updatedAt.isAfter(selectedProgress.updatedAt)) {
        selected = chapter;
      }
    }
    return selected;
  }

  ImportedLibraryEntry? get resumeChapter => lastReadChapter ?? latestChapter;

  DateTime get latestImportedAt {
    if (chapters.isEmpty) {
      return savedAt;
    }
    return chapters.fold<DateTime>(
      savedAt,
      (latest, entry) => entry.chapter.importedAt.isAfter(latest)
          ? entry.chapter.importedAt
          : latest,
    );
  }

  DateTime get latestUpdatedAt {
    var latest = metadataUpdatedAt;
    for (final entry in chapters) {
      if (entry.chapter.importedAt.isAfter(latest)) {
        latest = entry.chapter.importedAt;
      }
      final progress = entry.progress;
      if (progress != null && progress.updatedAt.isAfter(latest)) {
        latest = progress.updatedAt;
      }
    }
    return latest;
  }
}

/// Collapses source-owned aliases into one read-only library projection.
///
/// [canonicalIdentity] is comparison-only. The selected [LibraryComic] keeps
/// its original source [LibraryComic.comicId], so plugin request locators and
/// chapter ownership never get rewritten by the catalog projection.
List<LibraryComic> collapseCanonicalLibraryComics(
  Iterable<LibraryComic> comics, {
  required String Function(String sourceId, String comicId) canonicalIdentity,
  bool Function(String chapterId)? isCompatibilityChapter,
}) {
  final grouped = <String, List<LibraryComic>>{};
  for (final comic in comics) {
    final identity = canonicalIdentity(comic.sourceId, comic.comicId);
    grouped.putIfAbsent(identity, () => <LibraryComic>[]).add(comic);
  }
  final collapsed = <LibraryComic>[
    for (final aliases in grouped.values)
      preferredLibraryComicAlias(
        aliases,
        isCompatibilityChapter: isCompatibilityChapter,
      ),
  ]
    ..sort((left, right) {
      final recent = right.latestUpdatedAt.compareTo(left.latestUpdatedAt);
      return recent != 0 ? recent : left.identity.compareTo(right.identity);
    });
  return List<LibraryComic>.unmodifiable(collapsed);
}

/// Selects the strongest durable alias without changing its raw identity.
///
/// A richer authoritative catalog wins over a one-chapter or compatibility
/// projection. Downloaded chapters and page counts are secondary evidence.
LibraryComic preferredLibraryComicAlias(
  Iterable<LibraryComic> aliases, {
  bool Function(String chapterId)? isCompatibilityChapter,
}) {
  final values = aliases.toList(growable: false);
  if (values.isEmpty) {
    throw ArgumentError.value(aliases, 'aliases', 'must not be empty');
  }
  final compatibility = isCompatibilityChapter ?? (_) => false;
  return values.reduce(
    (left, right) => _compareLibraryComicAliasQuality(
              left,
              right,
              compatibility,
            ) >=
            0
        ? left
        : right,
  );
}

int _compareLibraryComicAliasQuality(
  LibraryComic left,
  LibraryComic right,
  bool Function(String chapterId) isCompatibilityChapter,
) {
  final leftReal = left.sourceChapters
      .where((chapter) => !isCompatibilityChapter(chapter.chapterId))
      .length;
  final rightReal = right.sourceChapters
      .where((chapter) => !isCompatibilityChapter(chapter.chapterId))
      .length;
  var result = leftReal.compareTo(rightReal);
  if (result != 0) return result;
  result = left.sourceChapters.length.compareTo(right.sourceChapters.length);
  if (result != 0) return result;
  result = left.chapters.length.compareTo(right.chapters.length);
  if (result != 0) return result;
  result = left.totalPages.compareTo(right.totalPages);
  if (result != 0) return result;
  result = left.metadataUpdatedAt.compareTo(right.metadataUpdatedAt);
  if (result != 0) return result;
  result = right.comicId.length.compareTo(left.comicId.length);
  if (result != 0) return result;
  return right.comicId.compareTo(left.comicId);
}

List<LibraryComic> aggregateImportedLibrary(
  Iterable<ImportedLibraryEntry> entries, {
  Iterable<SavedComicRecord> savedComics = const <SavedComicRecord>[],
}) {
  final grouped = <String, List<ImportedLibraryEntry>>{};
  for (final entry in entries) {
    final identity = '${entry.chapter.sourceId}\u0000${entry.chapter.comicId}';
    grouped.putIfAbsent(identity, () => <ImportedLibraryEntry>[])..add(entry);
  }
  final savedByIdentity = <String, SavedComicRecord>{
    for (final comic in savedComics) comic.identity: comic,
  };
  final identities = <String>{...grouped.keys, ...savedByIdentity.keys};
  final comics = <LibraryComic>[
    for (final identity in identities)
      LibraryComic.fromEntries(
        grouped[identity] ?? const <ImportedLibraryEntry>[],
        savedComic: savedByIdentity[identity],
      ),
  ]
    ..sort((left, right) {
      final recent = right.latestUpdatedAt.compareTo(left.latestUpdatedAt);
      return recent != 0 ? recent : left.identity.compareTo(right.identity);
    });
  return List<LibraryComic>.unmodifiable(comics);
}

int _compareChapters(
  ImportedLibraryEntry left,
  ImportedLibraryEntry right,
) {
  final sequence = left.chapter.sequence.compareTo(right.chapter.sequence);
  if (sequence != 0) {
    return sequence;
  }
  final imported = left.chapter.importedAt.compareTo(right.chapter.importedAt);
  if (imported != 0) {
    return imported;
  }
  return left.chapter.chapterId.compareTo(right.chapter.chapterId);
}

int _compareLatest(
  ImportedLibraryEntry left,
  ImportedLibraryEntry right,
) {
  final imported = left.chapter.importedAt.compareTo(right.chapter.importedAt);
  if (imported != 0) {
    return imported;
  }
  final sequence = left.chapter.sequence.compareTo(right.chapter.sequence);
  if (sequence != 0) {
    return sequence;
  }
  return left.chapter.chapterId.compareTo(right.chapter.chapterId);
}

int _metadataScore(ImportedChapterRecord chapter) {
  var score = 0;
  if (chapter.comicAuthors.isNotEmpty) {
    score += 1;
  }
  if (chapter.comicDescription != null) {
    score += 2;
  }
  if (chapter.coverSourceId != null) {
    score += 1;
  }
  return score;
}

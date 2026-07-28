import 'imported_library_store.dart';

/// Comic-level projection over one or more persisted chapter entries.
///
/// The aggregate does not own storage. It groups immutable store snapshots so
/// Home, Bookshelf and details routes share one comic identity while chapter
/// refresh/progress remain authoritative in [ImportedLibraryStore].
final class LibraryComic {
  LibraryComic({
    required this.comicId,
    required this.title,
    required Iterable<ImportedLibraryEntry> chapters,
  }) : chapters = List<ImportedLibraryEntry>.unmodifiable(
          chapters.toList(growable: false)..sort(_compareChapters),
        ) {
    if (comicId.trim().isEmpty || title.trim().isEmpty) {
      throw ArgumentError('comic identity and title must be non-empty');
    }
    if (this.chapters.isEmpty) {
      throw ArgumentError.value(chapters, 'chapters', 'must not be empty');
    }
    for (final entry in this.chapters) {
      if (entry.chapter.comicId != comicId) {
        throw ArgumentError.value(
          entry.chapter.comicId,
          'chapters',
          'contains a different comic identity',
        );
      }
    }
  }

  factory LibraryComic.fromEntries(Iterable<ImportedLibraryEntry> entries) {
    final chapters = entries.toList(growable: false);
    if (chapters.isEmpty) {
      throw ArgumentError.value(entries, 'entries', 'must not be empty');
    }
    final comicId = chapters.first.chapter.comicId;
    final newest = chapters.reduce(
      (left, right) => right.chapter.importedAt.isAfter(left.chapter.importedAt)
          ? right
          : left,
    );
    return LibraryComic(
      comicId: comicId,
      title: newest.chapter.comicTitle,
      chapters: chapters,
    );
  }

  final String comicId;
  final String title;
  final List<ImportedLibraryEntry> chapters;

  bool get hasMultipleChapters => chapters.length > 1;

  int get totalPages => chapters.fold<int>(
        0,
        (total, entry) => total + entry.chapter.pages.length,
      );

  Set<String> get sourceIds => Set<String>.unmodifiable(
        chapters.map((entry) => entry.chapter.sourceId),
      );

  ImportedLibraryEntry get coverChapter => chapters.first;

  ImportedLibraryEntry get latestChapter => chapters.reduce(
        (left, right) => _compareLatest(left, right) >= 0 ? left : right,
      );

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

  ImportedLibraryEntry get resumeChapter => lastReadChapter ?? latestChapter;

  DateTime get latestImportedAt => chapters.fold<DateTime>(
        chapters.first.chapter.importedAt,
        (latest, entry) => entry.chapter.importedAt.isAfter(latest)
            ? entry.chapter.importedAt
            : latest,
      );

  DateTime get latestUpdatedAt {
    var latest = chapters.first.chapter.importedAt;
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

List<LibraryComic> aggregateImportedLibrary(
  Iterable<ImportedLibraryEntry> entries,
) {
  final grouped = <String, List<ImportedLibraryEntry>>{};
  for (final entry in entries) {
    grouped.putIfAbsent(entry.chapter.comicId, () => <ImportedLibraryEntry>[])
      ..add(entry);
  }
  final comics = grouped.values
      .map(LibraryComic.fromEntries)
      .toList(growable: false)
    ..sort((left, right) {
      final recent = right.latestImportedAt.compareTo(left.latestImportedAt);
      return recent != 0 ? recent : left.comicId.compareTo(right.comicId);
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

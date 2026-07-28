import 'imported_library_store.dart';
import 'imported_chapter.dart';

/// Comic-level projection over one or more persisted chapter entries.
///
/// The aggregate does not own storage. It groups immutable store snapshots so
/// Home, Bookshelf and details routes share one comic identity while chapter
/// refresh/progress remain authoritative in [ImportedLibraryStore].
final class LibraryComic {
  LibraryComic({
    required this.sourceId,
    required this.comicId,
    required this.title,
    required Iterable<String> authors,
    required this.description,
    required Iterable<ImportedLibraryEntry> chapters,
  })  : authors = List<String>.unmodifiable(authors),
        chapters = List<ImportedLibraryEntry>.unmodifiable(
          chapters.toList(growable: false)..sort(_compareChapters),
        ) {
    if (sourceId.trim().isEmpty ||
        comicId.trim().isEmpty ||
        title.trim().isEmpty) {
      throw ArgumentError('source, comic identity and title must be non-empty');
    }
    if (this.chapters.isEmpty) {
      throw ArgumentError.value(chapters, 'chapters', 'must not be empty');
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

  factory LibraryComic.fromEntries(Iterable<ImportedLibraryEntry> entries) {
    final chapters = entries.toList(growable: false);
    if (chapters.isEmpty) {
      throw ArgumentError.value(entries, 'entries', 'must not be empty');
    }
    final sourceId = chapters.first.chapter.sourceId;
    final comicId = chapters.first.chapter.comicId;
    final newest = chapters.reduce(
      (left, right) => right.chapter.importedAt.isAfter(left.chapter.importedAt)
          ? right
          : left,
    );
    final metadata = chapters.fold<ImportedLibraryEntry>(
      newest,
      (selected, entry) {
        final selectedScore = _metadataScore(selected.chapter);
        final entryScore = _metadataScore(entry.chapter);
        if (entryScore != selectedScore) {
          return entryScore > selectedScore ? entry : selected;
        }
        return entry.chapter.importedAt.isAfter(selected.chapter.importedAt)
            ? entry
            : selected;
      },
    );
    final authors = <String>{};
    for (final entry in chapters) {
      authors.addAll(entry.chapter.comicAuthors);
    }
    return LibraryComic(
      sourceId: sourceId,
      comicId: comicId,
      title: metadata.chapter.comicTitle,
      authors: authors,
      description: metadata.chapter.comicDescription,
      chapters: chapters,
    );
  }

  final String sourceId;
  final String comicId;
  final String title;
  final List<String> authors;
  final String? description;
  final List<ImportedLibraryEntry> chapters;

  bool get hasMultipleChapters => chapters.length > 1;

  int get totalPages => chapters.fold<int>(
        0,
        (total, entry) => total + entry.chapter.pages.length,
      );

  Set<String> get sourceIds => Set<String>.unmodifiable(<String>{sourceId});

  ImportedLibraryEntry get coverChapter {
    for (final chapter in chapters.reversed) {
      if (chapter.chapter.coverSourceId != null) {
        return chapter;
      }
    }
    return chapters.first;
  }

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
    final identity = '${entry.chapter.sourceId}\u0000${entry.chapter.comicId}';
    grouped.putIfAbsent(identity, () => <ImportedLibraryEntry>[])..add(entry);
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

import 'package:domain/domain.dart';

import 'imported_chapter.dart';

final class ImportedLibraryEntry {
  const ImportedLibraryEntry({
    required this.chapter,
    this.progress,
  });

  final ImportedChapterRecord chapter;
  final ReadingProgress? progress;

  ImportedLibraryEntry copyWith({
    ImportedChapterRecord? chapter,
    ReadingProgress? progress,
    bool clearProgress = false,
  }) {
    return ImportedLibraryEntry(
      chapter: chapter ?? this.chapter,
      progress: clearProgress ? null : (progress ?? this.progress),
    );
  }
}

abstract interface class ImportedLibraryStore {
  Future<void> open();

  Future<List<ImportedLibraryEntry>> list();

  Future<ImportedLibraryEntry?> get(String chapterId);

  Future<void> upsertChapter(ImportedChapterRecord chapter);

  Future<void> saveProgress(ReadingProgress progress);

  Future<void> removeChapter(String chapterId);

  Future<void> close();
}

final class MemoryImportedLibraryStore implements ImportedLibraryStore {
  final Map<String, ImportedChapterRecord> _chapters =
      <String, ImportedChapterRecord>{};
  final Map<String, ReadingProgress> _progress = <String, ReadingProgress>{};
  bool _open = false;

  @override
  Future<void> open() async {
    _open = true;
  }

  @override
  Future<List<ImportedLibraryEntry>> list() async {
    _requireOpen();
    final values = _chapters.values.toList(growable: false)
      ..sort((left, right) {
        final imported = right.importedAt.compareTo(left.importedAt);
        if (imported != 0) {
          return imported;
        }
        return left.chapterId.compareTo(right.chapterId);
      });
    return values
        .map(
          (chapter) => ImportedLibraryEntry(
            chapter: chapter,
            progress: _progress[chapter.chapterId],
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<ImportedLibraryEntry?> get(String chapterId) async {
    _requireOpen();
    final chapter = _chapters[chapterId];
    if (chapter == null) {
      return null;
    }
    return ImportedLibraryEntry(
      chapter: chapter,
      progress: _progress[chapterId],
    );
  }

  @override
  Future<void> upsertChapter(ImportedChapterRecord chapter) async {
    _requireOpen();
    _chapters[chapter.chapterId] = chapter;
    final progress = _progress[chapter.chapterId];
    if (progress != null && progress.pageIndex >= chapter.pages.length) {
      _progress[chapter.chapterId] = ReadingProgress(
        comicId: chapter.comicId,
        chapterId: chapter.chapterId,
        pageIndex: chapter.pages.length - 1,
        subPageOffset: 0,
        readerMode: progress.readerMode,
        updatedAt: progress.updatedAt,
      );
    }
  }

  @override
  Future<void> saveProgress(ReadingProgress progress) async {
    _requireOpen();
    final chapter = _chapters[progress.chapterId];
    if (chapter == null) {
      throw StateError('cannot save progress for an unknown chapter');
    }
    if (progress.comicId != chapter.comicId) {
      throw StateError('progress comic identity does not match the chapter');
    }
    if (progress.pageIndex < 0 || progress.pageIndex >= chapter.pages.length) {
      throw RangeError.range(
        progress.pageIndex,
        0,
        chapter.pages.length - 1,
        'progress.pageIndex',
      );
    }
    final current = _progress[progress.chapterId];
    if (current == null || !progress.updatedAt.isBefore(current.updatedAt)) {
      _progress[progress.chapterId] = progress;
    }
  }

  @override
  Future<void> removeChapter(String chapterId) async {
    _requireOpen();
    _chapters.remove(chapterId);
    _progress.remove(chapterId);
  }

  @override
  Future<void> close() async {
    _open = false;
  }

  void _requireOpen() {
    if (!_open) {
      throw StateError('imported library store is not open');
    }
  }
}

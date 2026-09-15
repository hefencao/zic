import 'package:domain/domain.dart';

abstract interface class ComicSource {
  String get sourceId;

  Future<ComicManifest> loadComic(String comicId);

  Future<ChapterManifest> loadChapter(String chapterId);
}

/// Optional scheduler-controlled companion for comic/chapter metadata.
///
/// The caller still owns scheduling policy through [TaskControl]. Sources may
/// only observe cancellation/priority and must not create a second scheduler.
abstract interface class ControlledComicSource {
  Future<ComicManifest> loadComicControlled(
    String comicId, {
    TaskControl? control,
  });

  Future<ChapterManifest> loadChapterControlled(
    String chapterId, {
    TaskControl? control,
  });
}

/// Optional source capability for bypassing reusable chapter metadata.
///
/// Callers use this only when a persisted adapter locator is known to belong
/// to an obsolete generation. The capability returns fresh metadata; it does
/// not delete Reader/download page artifacts.
abstract interface class RefreshableChapterComicSource {
  Future<ChapterManifest> refreshChapter(String chapterId);
}

abstract interface class ControlledRefreshableChapterComicSource {
  Future<ChapterManifest> refreshChapterControlled(
    String chapterId, {
    TaskControl? control,
  });
}

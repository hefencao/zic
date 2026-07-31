import 'package:domain/domain.dart';

abstract interface class ComicSource {
  String get sourceId;

  Future<ComicManifest> loadComic(String comicId);

  Future<ChapterManifest> loadChapter(String chapterId);
}

/// Optional source capability for bypassing reusable chapter metadata.
///
/// Callers use this only when a persisted adapter locator is known to belong
/// to an obsolete generation. The capability returns fresh metadata; it does
/// not delete Reader/download page artifacts.
abstract interface class RefreshableChapterComicSource {
  Future<ChapterManifest> refreshChapter(String chapterId);
}

import 'package:domain/domain.dart';

abstract interface class ComicSource {
  String get sourceId;

  Future<ComicManifest> loadComic(String comicId);

  Future<ChapterManifest> loadChapter(String chapterId);
}

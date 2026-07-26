import 'dart:convert';

import 'package:domain/domain.dart';

import 'comic_source.dart';
import 'manifest_parser.dart';

typedef TextAssetLoader = Future<String> Function(String key);

final class LocalManifestSource implements ComicSource {
  LocalManifestSource({
    required this.sourceId,
    required TextAssetLoader loader,
    required Map<String, String> comicManifestPaths,
    required Map<String, String> chapterManifestPaths,
  })  : _loader = loader,
        _comicManifestPaths = Map<String, String>.unmodifiable(comicManifestPaths),
        _chapterManifestPaths =
            Map<String, String>.unmodifiable(chapterManifestPaths);

  @override
  final String sourceId;

  final TextAssetLoader _loader;
  final Map<String, String> _comicManifestPaths;
  final Map<String, String> _chapterManifestPaths;

  @override
  Future<ComicManifest> loadComic(String comicId) async {
    final path = _comicManifestPaths[comicId];
    if (path == null) {
      throw StateError('unknown comic: $comicId');
    }
    final decoded = jsonDecode(await _loader(path));
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('comic manifest root must be an object');
    }

    final chaptersJson = decoded['chapters'];
    if (chaptersJson is! List<Object?>) {
      throw const FormatException('chapters must be a list');
    }
    final chapters = chaptersJson.map((value) {
      if (value is! Map<String, Object?>) {
        throw const FormatException('chapter entry must be an object');
      }
      return Chapter(
        chapterId: value['chapterId']! as String,
        comicId: comicId,
        title: value['title']! as String,
        sequence: value['sequence']! as int,
        pageCount: value['pageCount']! as int,
        sourceRevision: value['sourceRevision']! as String,
      );
    }).toList(growable: false);

    return ComicManifest(
      comic: Comic(
        comicId: comicId,
        sourceId: sourceId,
        title: decoded['title']! as String,
        authors: (decoded['authors']! as List<Object?>).cast<String>(),
        coverUri: decoded['coverUri'] == null
            ? null
            : Uri.parse(decoded['coverUri']! as String),
        readingDirection: ReadingDirection.values.byName(
          (decoded['readingDirection'] as String?) ?? ReadingDirection.ltr.name,
        ),
      ),
      chapters: chapters,
    );
  }

  @override
  Future<ChapterManifest> loadChapter(String chapterId) async {
    final path = _chapterManifestPaths[chapterId];
    if (path == null) {
      throw StateError('unknown chapter: $chapterId');
    }
    final manifest = parseChapterManifest(await _loader(path));
    if (manifest.sourceId != sourceId) {
      throw StateError(
        'manifest source ${manifest.sourceId} does not match $sourceId',
      );
    }
    return manifest;
  }
}

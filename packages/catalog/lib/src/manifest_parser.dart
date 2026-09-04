import 'dart:convert';

import 'package:domain/domain.dart';

ChapterManifest parseChapterManifest(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('chapter manifest root must be an object');
  }

  final sourceId = _requiredString(decoded, 'sourceId');
  final comicId = _requiredString(decoded, 'comicId');
  final chapterJson = _requiredMap(decoded, 'chapter');
  final pagesJson = decoded['pages'];
  if (pagesJson is! List<Object?>) {
    throw const FormatException('pages must be a list');
  }

  final chapter = Chapter(
    chapterId: _requiredString(chapterJson, 'chapterId'),
    comicId: comicId,
    title: _requiredString(chapterJson, 'title'),
    sequence: _requiredInt(chapterJson, 'sequence'),
    pageCount: _requiredInt(chapterJson, 'pageCount'),
    sourceRevision: _requiredString(chapterJson, 'sourceRevision'),
    publishedAt: _optionalDate(chapterJson['publishedAt']),
  );

  final pages = <PageAsset>[];
  for (final value in pagesJson) {
    if (value is! Map<String, Object?>) {
      throw const FormatException('page entry must be an object');
    }
    pages.add(
      PageAsset(
        pageId: _requiredString(value, 'pageId'),
        chapterId: chapter.chapterId,
        index: _requiredInt(value, 'index'),
        uri: Uri.parse(_requiredString(value, 'uri')),
        width: _optionalInt(value['width']),
        height: _optionalInt(value['height']),
        byteLength: _optionalInt(value['byteLength']),
        contentKindHint: ContentKindHint.values.byName(
          (value['contentKindHint'] as String?) ?? ContentKindHint.unknown.name,
        ),
        animatedHint: (value['animatedHint'] as bool?) ?? false,
        checksum: value['checksum'] as String?,
        checksumAlgorithm: value['checksumAlgorithm'] as String?,
      ),
    );
  }

  return ChapterManifest(
    sourceId: sourceId,
    comicId: comicId,
    chapter: chapter,
    pages: pages,
    readingDirection: ReadingDirection.values.byName(
      (decoded['readingDirection'] as String?) ?? ReadingDirection.ltr.name,
    ),
  );
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}

int _requiredInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) {
    throw FormatException('$key must be an integer');
  }
  return value;
}

Map<String, Object?> _requiredMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map<String, Object?>) {
    throw FormatException('$key must be an object');
  }
  return value;
}

int? _optionalInt(Object? value) => value == null ? null : value as int;

DateTime? _optionalDate(Object? value) =>
    value == null ? null : DateTime.parse(value as String);

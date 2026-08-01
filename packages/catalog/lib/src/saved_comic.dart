import 'package:domain/domain.dart';

/// Durable comic-level metadata independent of downloaded/imported chapters.
///
/// A remote comic can therefore be collected or added to the shelf without
/// implicitly persisting one arbitrary chapter. Chapter manifests and offline
/// bytes remain separate resources owned by their respective stores.
final class SavedChapterRecord {
  const SavedChapterRecord({
    required this.chapterId,
    required this.title,
    required this.sequence,
    required this.pageCount,
    required this.sourceRevision,
    this.publishedAt,
  });

  factory SavedChapterRecord.fromChapter(Chapter chapter) =>
      SavedChapterRecord(
        chapterId: chapter.chapterId,
        title: chapter.title,
        sequence: chapter.sequence,
        pageCount: chapter.pageCount,
        sourceRevision: chapter.sourceRevision,
        publishedAt: chapter.publishedAt,
      );

  final String chapterId;
  final String title;
  final int sequence;
  final int pageCount;
  final String sourceRevision;
  final DateTime? publishedAt;

  Chapter toChapter(String comicId) => Chapter(
        chapterId: chapterId,
        comicId: comicId,
        title: title,
        sequence: sequence,
        pageCount: pageCount,
        sourceRevision: sourceRevision,
        publishedAt: publishedAt,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'chapterId': chapterId,
        'title': title,
        'sequence': sequence,
        'pageCount': pageCount,
        'sourceRevision': sourceRevision,
        if (publishedAt != null)
          'publishedAt': publishedAt!.toUtc().toIso8601String(),
      };

  factory SavedChapterRecord.fromJson(Map<String, Object?> json) =>
      SavedChapterRecord(
        chapterId: _requiredString(json, 'chapterId'),
        title: _requiredString(json, 'title'),
        sequence: json['sequence']! as int,
        pageCount: json['pageCount']! as int,
        sourceRevision: _requiredString(json, 'sourceRevision'),
        publishedAt: json['publishedAt'] == null
            ? null
            : DateTime.parse(json['publishedAt']! as String),
      );
}

final class SavedComicRecord {
  SavedComicRecord({
    required this.sourceId,
    required this.comicId,
    required this.title,
    Iterable<String> authors = const <String>[],
    Iterable<String> tags = const <String>[],
    this.description,
    this.coverSourceId,
    this.readingDirection = ReadingDirection.ltr,
    Iterable<SavedChapterRecord> chapters = const <SavedChapterRecord>[],
    DateTime? savedAt,
    DateTime? updatedAt,
  })  : chapters = List<SavedChapterRecord>.unmodifiable(
          chapters.toList(growable: false)..sort(
                (left, right) => left.sequence.compareTo(right.sequence),
              ),
        ),
        authors = List<String>.unmodifiable(
          authors
              .map((author) => author.trim())
              .where((author) => author.isNotEmpty),
        ),
        tags = List<String>.unmodifiable(
          tags
              .map((tag) => tag.trim())
              .where((tag) => tag.isNotEmpty)
              .toSet(),
        ),
        savedAt = (savedAt ?? DateTime.now()).toUtc(),
        updatedAt = (updatedAt ?? DateTime.now()).toUtc() {
    if (sourceId.trim().isEmpty ||
        comicId.trim().isEmpty ||
        title.trim().isEmpty) {
      throw ArgumentError('source, comic identity and title must be non-empty');
    }
    if (description != null && description!.trim().isEmpty) {
      throw ArgumentError.value(description, 'description', 'must not be blank');
    }
    if (coverSourceId != null && coverSourceId!.trim().isEmpty) {
      throw ArgumentError.value(
        coverSourceId,
        'coverSourceId',
        'must not be blank',
      );
    }
  }

  factory SavedComicRecord.fromComic(
    Comic comic, {
    DateTime? savedAt,
    DateTime? updatedAt,
  }) =>
      SavedComicRecord(
        sourceId: comic.sourceId,
        comicId: comic.comicId,
        title: comic.title,
        authors: comic.authors,
        tags: comic.tags,
        description: comic.description,
        coverSourceId: comic.coverUri?.toString(),
        readingDirection: comic.readingDirection,
        savedAt: savedAt,
        updatedAt: updatedAt ?? comic.updatedAt,
      );

  factory SavedComicRecord.fromManifest(
    ComicManifest manifest, {
    DateTime? savedAt,
    DateTime? updatedAt,
  }) =>
      SavedComicRecord(
        sourceId: manifest.comic.sourceId,
        comicId: manifest.comic.comicId,
        title: manifest.comic.title,
        authors: manifest.comic.authors,
        tags: manifest.comic.tags,
        description: manifest.comic.description,
        coverSourceId: manifest.comic.coverUri?.toString(),
        readingDirection: manifest.comic.readingDirection,
        chapters: manifest.chapters.map(SavedChapterRecord.fromChapter),
        savedAt: savedAt,
        updatedAt: updatedAt ?? manifest.comic.updatedAt,
      );

  final String sourceId;
  final String comicId;
  final String title;
  final List<String> authors;
  final List<String> tags;
  final String? description;
  final String? coverSourceId;
  final ReadingDirection readingDirection;
  final List<SavedChapterRecord> chapters;
  final DateTime savedAt;
  final DateTime updatedAt;

  String get identity => '$sourceId\u0000$comicId';

  Comic toComic() => Comic(
        comicId: comicId,
        sourceId: sourceId,
        title: title,
        authors: authors,
        tags: tags,
        coverUri: coverSourceId == null ? null : Uri.tryParse(coverSourceId!),
        description: description,
        readingDirection: readingDirection,
        updatedAt: updatedAt,
      );

  SavedComicRecord copyWith({
    String? title,
    Iterable<String>? authors,
    Iterable<String>? tags,
    String? description,
    bool clearDescription = false,
    String? coverSourceId,
    bool clearCoverSourceId = false,
    ReadingDirection? readingDirection,
    Iterable<SavedChapterRecord>? chapters,
    DateTime? savedAt,
    DateTime? updatedAt,
  }) =>
      SavedComicRecord(
        sourceId: sourceId,
        comicId: comicId,
        title: title ?? this.title,
        authors: authors ?? this.authors,
        tags: tags ?? this.tags,
        description:
            clearDescription ? null : (description ?? this.description),
        coverSourceId:
            clearCoverSourceId ? null : (coverSourceId ?? this.coverSourceId),
        readingDirection: readingDirection ?? this.readingDirection,
        chapters: chapters ?? this.chapters,
        savedAt: savedAt ?? this.savedAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'sourceId': sourceId,
        'comicId': comicId,
        'title': title,
        'authors': authors,
        'tags': tags,
        if (description != null) 'description': description,
        if (coverSourceId != null) 'coverSourceId': coverSourceId,
        'readingDirection': readingDirection.name,
        'chapters': chapters.map((chapter) => chapter.toJson()).toList(),
        'savedAt': savedAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory SavedComicRecord.fromJson(Map<String, Object?> json) {
    final rawAuthors = json['authors'];
    if (rawAuthors != null &&
        (rawAuthors is! List<Object?> ||
            rawAuthors.any((author) => author is! String))) {
      throw const FormatException('authors must be a string list');
    }
    final authors = rawAuthors == null
        ? const <String>[]
        : (rawAuthors as List<Object?>).cast<String>();
    final rawTags = json['tags'];
    if (rawTags != null &&
        (rawTags is! List<Object?> ||
            rawTags.any((tag) => tag is! String))) {
      throw const FormatException('tags must be a string list');
    }
    final tags = rawTags == null
        ? const <String>[]
        : (rawTags as List<Object?>).cast<String>();

    final rawChapters = json['chapters'];
    if (rawChapters != null && rawChapters is! List<Object?>) {
      throw const FormatException('chapters must be a list');
    }
    final chapterValues = rawChapters == null
        ? const <Object?>[]
        : rawChapters as List<Object?>;

    return SavedComicRecord(
      sourceId: _requiredString(json, 'sourceId'),
      comicId: _requiredString(json, 'comicId'),
      title: _requiredString(json, 'title'),
      authors: authors,
      tags: tags,
      description: json['description'] as String?,
      coverSourceId: json['coverSourceId'] as String?,
      readingDirection: ReadingDirection.values.byName(
        (json['readingDirection'] as String?) ?? ReadingDirection.ltr.name,
      ),
      chapters: chapterValues.map((value) {
        if (value is! Map) {
          throw const FormatException('chapter must be an object');
        }
        return SavedChapterRecord.fromJson(
          Map<String, Object?>.from(value),
        );
      }),
      savedAt: DateTime.parse(_requiredString(json, 'savedAt')),
      updatedAt: DateTime.parse(_requiredString(json, 'updatedAt')),
    );
  }
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}

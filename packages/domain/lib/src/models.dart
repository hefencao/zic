enum ReadingDirection { ltr, rtl, vertical }

enum ReaderMode { paged, continuous }

enum ContentKindHint { unknown, jpeg, png, webp, gif, avif, fallback }

final class Comic {
  const Comic({
    required this.comicId,
    required this.sourceId,
    required this.title,
    required this.authors,
    required this.readingDirection,
    this.tags = const <String>[],
    this.coverUri,
    this.description,
    this.createdAt,
    this.updatedAt,
  });

  final String comicId;
  final String sourceId;
  final String title;
  final List<String> authors;
  final List<String> tags;
  final Uri? coverUri;
  final String? description;
  final ReadingDirection readingDirection;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}

final class Chapter {
  const Chapter({
    required this.chapterId,
    required this.comicId,
    required this.title,
    required this.sequence,
    required this.pageCount,
    required this.sourceRevision,
    this.publishedAt,
  });

  final String chapterId;
  final String comicId;
  final String title;
  final int sequence;
  final int pageCount;
  final DateTime? publishedAt;
  final String sourceRevision;
}

final class PageAsset {
  const PageAsset({
    required this.pageId,
    required this.chapterId,
    required this.index,
    required this.uri,
    this.width,
    this.height,
    this.byteLength,
    this.contentKindHint = ContentKindHint.unknown,
    this.animatedHint = false,
    this.checksum,
  });

  final String pageId;
  final String chapterId;
  final int index;
  final Uri uri;
  final int? width;
  final int? height;
  final int? byteLength;
  final ContentKindHint contentKindHint;
  final bool animatedHint;
  final String? checksum;

  String get assetKey => '$chapterId/$pageId';
}

final class ReadingProgress {
  const ReadingProgress({
    required this.sourceId,
    required this.comicId,
    required this.chapterId,
    required this.pageIndex,
    required this.subPageOffset,
    required this.readerMode,
    required this.updatedAt,
  });

  final String sourceId;
  final String comicId;
  final String chapterId;
  final int pageIndex;
  final double subPageOffset;
  final ReaderMode readerMode;
  final DateTime updatedAt;

  String get identity => '$sourceId\u0000$chapterId';

  Map<String, Object> toJson() => <String, Object>{
        'sourceId': sourceId,
        'comicId': comicId,
        'chapterId': chapterId,
        'pageIndex': pageIndex,
        'subPageOffset': subPageOffset,
        'readerMode': readerMode.name,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  factory ReadingProgress.fromJson(
    Map<String, Object?> json, {
    String? fallbackSourceId,
  }) {
    final sourceId = (json['sourceId'] as String?) ?? fallbackSourceId;
    if (sourceId == null || sourceId.trim().isEmpty) {
      throw const FormatException('sourceId must be a non-empty string');
    }
    return ReadingProgress(
      sourceId: sourceId,
      comicId: json['comicId']! as String,
      chapterId: json['chapterId']! as String,
      pageIndex: json['pageIndex']! as int,
      subPageOffset: (json['subPageOffset']! as num).toDouble(),
      readerMode: ReaderMode.values.byName(json['readerMode']! as String),
      updatedAt: DateTime.parse(json['updatedAt']! as String),
    );
  }
}

final class ComicManifest {
  const ComicManifest({required this.comic, required this.chapters});

  final Comic comic;
  final List<Chapter> chapters;
}

final class ChapterManifest {
  ChapterManifest({
    required this.sourceId,
    required this.comicId,
    required this.chapter,
    required List<PageAsset> pages,
    required this.readingDirection,
  }) : pages = List<PageAsset>.unmodifiable(pages) {
    if (chapter.pageCount != pages.length) {
      throw ArgumentError(
        'chapter.pageCount (${chapter.pageCount}) != pages.length (${pages.length})',
      );
    }
    for (var i = 0; i < pages.length; i++) {
      if (pages[i].index != i) {
        throw ArgumentError('page index at position $i is ${pages[i].index}');
      }
      if (pages[i].chapterId != chapter.chapterId) {
        throw ArgumentError('page ${pages[i].pageId} belongs to another chapter');
      }
    }
  }

  final String sourceId;
  final String comicId;
  final Chapter chapter;
  final List<PageAsset> pages;
  final ReadingDirection readingDirection;
}

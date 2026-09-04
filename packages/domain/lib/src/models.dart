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
    this.sourceSubId,
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
  /// Optional source-owned secondary identity used by detail-side APIs.
  final String? sourceSubId;
  final ReadingDirection readingDirection;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}

final class ComicPreviewAsset {
  const ComicPreviewAsset({
    required this.uri,
    this.label,
    this.width,
    this.height,
  });

  final Uri uri;
  final String? label;
  final int? width;
  final int? height;
}

final class ComicPreviewPage {
  ComicPreviewPage({
    required Iterable<ComicPreviewAsset> items,
    this.nextToken,
  }) : items = List<ComicPreviewAsset>.unmodifiable(items);

  final List<ComicPreviewAsset> items;
  final String? nextToken;

  bool get hasMore => nextToken != null && nextToken!.isNotEmpty;
}

final class ComicComment {
  const ComicComment({
    required this.userName,
    required this.content,
    this.id,
    this.avatarUri,
    this.time,
    this.replyCount,
    this.score,
    this.isLiked,
    this.voteStatus,
  });

  final String? id;
  final String userName;
  final Uri? avatarUri;
  final String content;
  final String? time;
  final int? replyCount;
  final int? score;
  final bool? isLiked;
  final int? voteStatus;
}

final class ComicCommentPage {
  ComicCommentPage({
    required this.page,
    required Iterable<ComicComment> items,
    this.maxPage,
  }) : items = List<ComicComment>.unmodifiable(items) {
    if (page < 1 || (maxPage != null && maxPage! < page)) {
      throw ArgumentError('comic comment page is invalid');
    }
  }

  final int page;
  final List<ComicComment> items;
  final int? maxPage;

  bool get hasMore => maxPage == null || page < maxPage!;
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
    this.checksumAlgorithm,
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

  /// Algorithm for [checksum]. Download artifacts use `crc32` internally;
  /// source-provided hashes must declare their algorithm before they can be
  /// used as a transport completion constraint.
  final String? checksumAlgorithm;

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

  ReadingProgress copyWith({
    String? sourceId,
    String? comicId,
    String? chapterId,
    int? pageIndex,
    double? subPageOffset,
    ReaderMode? readerMode,
    DateTime? updatedAt,
  }) =>
      ReadingProgress(
        sourceId: sourceId ?? this.sourceId,
        comicId: comicId ?? this.comicId,
        chapterId: chapterId ?? this.chapterId,
        pageIndex: pageIndex ?? this.pageIndex,
        subPageOffset: subPageOffset ?? this.subPageOffset,
        readerMode: readerMode ?? this.readerMode,
        updatedAt: updatedAt ?? this.updatedAt,
      );

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
  const ComicManifest({
    required this.comic,
    required this.chapters,
    this.preview,
    this.comments,
  });

  final Comic comic;
  final List<Chapter> chapters;
  final ComicPreviewPage? preview;
  final ComicCommentPage? comments;
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

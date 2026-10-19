import 'package:domain/domain.dart';

/// Copies owned by ZIC, independently of the application they came from.
const externalDownloadsSourceId = 'local-download-import';

bool isLocalLibrarySource(String sourceId) =>
    sourceId == 'local-folder' || sourceId == externalDownloadsSourceId;

final class ImportedPageRecord {
  const ImportedPageRecord({
    required this.displayName,
    required this.sourceId,
    required this.contentKindHint,
    this.pageId,
    this.mediaFormat,
    this.byteLength,
    this.checksum,
    this.checksumAlgorithm,
    this.animatedHint = false,
  });

  final String displayName;
  final String sourceId;
  final ContentKindHint contentKindHint;
  final String? pageId;
  final String? mediaFormat;
  final int? byteLength;

  /// Optional source-declared content checksum. This remains source metadata
  /// until a local artifact owner independently verifies the same algorithm.
  final String? checksum;
  final String? checksumAlgorithm;
  final bool animatedHint;

  String get stablePageId => pageId ?? 'page-${_stableHash(sourceId)}';

  Uri get uri {
    if (_looksLikeWindowsPath(sourceId)) {
      return Uri.file(sourceId, windows: true);
    }
    if (sourceId.startsWith('/')) {
      return Uri.file(sourceId);
    }
    final parsed = Uri.tryParse(sourceId);
    if (parsed != null && parsed.hasScheme) {
      return parsed;
    }
    return Uri.file(sourceId);
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'displayName': displayName,
        'sourceId': sourceId,
        'contentKindHint': contentKindHint.name,
        if (pageId != null) 'pageId': pageId,
        if (mediaFormat != null) 'mediaFormat': mediaFormat,
        if (byteLength != null) 'byteLength': byteLength,
        if (checksum != null) 'checksum': checksum,
        if (checksumAlgorithm != null) 'checksumAlgorithm': checksumAlgorithm,
        'animatedHint': animatedHint,
      };

  factory ImportedPageRecord.fromJson(Map<String, Object?> json) {
    final displayName = _requiredString(json, 'displayName');
    final sourceId = _requiredString(json, 'sourceId');
    final kindName = _requiredString(json, 'contentKindHint');
    final rawPageId = json['pageId'];
    if (rawPageId != null &&
        (rawPageId is! String || rawPageId.trim().isEmpty)) {
      throw const FormatException('pageId must be a non-empty string');
    }
    final byteLength = json['byteLength'];
    if (byteLength != null && (byteLength is! int || byteLength < 0)) {
      throw const FormatException(
        'byteLength must be a non-negative integer',
      );
    }
    return ImportedPageRecord(
      displayName: displayName,
      sourceId: sourceId,
      contentKindHint: ContentKindHint.values.byName(kindName),
      pageId: rawPageId as String?,
      mediaFormat: json['mediaFormat'] as String?,
      byteLength: byteLength as int?,
      checksum: json['checksum'] as String?,
      checksumAlgorithm: json['checksumAlgorithm'] as String?,
      animatedHint: (json['animatedHint'] as bool?) ?? false,
    );
  }
}

final class ImportedChapterRecord {
  ImportedChapterRecord({
    required this.directoryId,
    required this.displayName,
    required this.sourceId,
    required this.comicId,
    required this.chapterId,
    required this.sourceRevision,
    required List<ImportedPageRecord> pages,
    String? comicTitle,
    Iterable<String> comicAuthors = const <String>[],
    Iterable<String> comicTags = const <String>[],
    this.comicDescription,
    this.coverSourceId,
    this.coverMediaFormat,
    this.coverAnimatedHint = false,
    this.directoryRecursive = true,
    this.sequence = 0,
    this.readingDirection = ReadingDirection.ltr,
    this.sourceUpdatedAt,
    DateTime? importedAt,
  })  : comicTitle = (comicTitle ?? displayName).trim(),
        comicAuthors = List<String>.unmodifiable(
          comicAuthors
              .map((author) => author.trim())
              .where((author) => author.isNotEmpty),
        ),
        comicTags = List<String>.unmodifiable(
          comicTags
              .map((tag) => tag.trim())
              .where((tag) => tag.isNotEmpty)
              .toSet(),
        ),
        pages = List<ImportedPageRecord>.unmodifiable(pages),
        importedAt = (importedAt ?? DateTime.now()).toUtc() {
    if (directoryId.trim().isEmpty ||
        displayName.trim().isEmpty ||
        sourceId.trim().isEmpty ||
        comicId.trim().isEmpty ||
        chapterId.trim().isEmpty ||
        sourceRevision.trim().isEmpty ||
        this.comicTitle.isEmpty) {
      throw ArgumentError('imported chapter identities must be non-empty');
    }
    if (this.comicDescription != null &&
        this.comicDescription!.trim().isEmpty) {
      throw ArgumentError.value(
        this.comicDescription,
        'comicDescription',
        'must be null or non-empty',
      );
    }
    if (coverMediaFormat != null && coverMediaFormat!.trim().isEmpty) {
      throw ArgumentError.value(
        coverMediaFormat,
        'coverMediaFormat',
        'must be null or non-empty',
      );
    }
    if (pages.isEmpty) {
      throw ArgumentError.value(pages, 'pages', 'must not be empty');
    }
    final pageIds = <String>{};
    for (final page in pages) {
      if (page.displayName.trim().isEmpty || page.sourceId.trim().isEmpty) {
        throw ArgumentError('imported page identity must be non-empty');
      }
      final stablePageId = page.stablePageId;
      if (stablePageId.trim().isEmpty || !pageIds.add(stablePageId)) {
        throw ArgumentError.value(
          stablePageId,
          'pages',
          'contains an empty or duplicate stable page identity',
        );
      }
      if (page.byteLength != null && page.byteLength! < 0) {
        throw ArgumentError.value(
          page.byteLength,
          'pages',
          'contains a negative byte length',
        );
      }
    }
  }

  factory ImportedChapterRecord.remote({
    required Comic comic,
    required ChapterManifest manifest,
    DateTime? importedAt,
  }) {
    if (comic.comicId != manifest.comicId ||
        manifest.chapter.comicId != manifest.comicId ||
        comic.sourceId != manifest.sourceId) {
      throw ArgumentError('remote comic and chapter identities must match');
    }
    return ImportedChapterRecord(
      directoryId: '${manifest.sourceId}:${manifest.comicId}',
      displayName: manifest.chapter.title,
      sourceId: manifest.sourceId,
      comicId: manifest.comicId,
      comicTitle: comic.title,
      comicAuthors: comic.authors,
      comicTags: comic.tags,
      comicDescription: comic.description,
      coverSourceId: comic.coverUri?.toString(),
      chapterId: manifest.chapter.chapterId,
      sourceRevision: manifest.chapter.sourceRevision,
      sequence: manifest.chapter.sequence,
      readingDirection: manifest.readingDirection,
      sourceUpdatedAt: manifest.chapter.updatedAt,
      importedAt: importedAt,
      pages: manifest.pages
          .map(
            (page) => ImportedPageRecord(
              displayName: _remoteDisplayName(page),
              sourceId: page.uri.toString(),
              contentKindHint: page.contentKindHint,
              pageId: page.pageId,
              mediaFormat: page.contentKindHint.name,
              byteLength: page.byteLength,
              checksum: page.checksum,
              checksumAlgorithm: page.checksumAlgorithm,
              animatedHint: page.animatedHint,
            ),
          )
          .toList(growable: false),
    );
  }

  factory ImportedChapterRecord.folder({
    required String directoryId,
    required String displayName,
    required List<ImportedPageRecord> pages,
    String? coverSourceId,
    String? coverMediaFormat,
    bool coverAnimatedHint = false,
    ReadingDirection readingDirection = ReadingDirection.ltr,
    DateTime? importedAt,
  }) {
    final normalizedDirectory = directoryId.trim();
    final normalizedName = displayName.trim();
    if (normalizedDirectory.isEmpty || normalizedName.isEmpty) {
      throw ArgumentError('directoryId and displayName must be non-empty');
    }
    if (pages.isEmpty) {
      throw ArgumentError.value(pages, 'pages', 'must not be empty');
    }
    final normalizedCover = coverSourceId?.trim();
    final effectiveCover = normalizedCover == null || normalizedCover.isEmpty
        ? pages.first.sourceId
        : normalizedCover;
    ImportedPageRecord? effectiveCoverPage;
    for (final page in pages) {
      if (page.sourceId == effectiveCover) {
        effectiveCoverPage = page;
        break;
      }
    }
    final effectiveCoverMediaFormat =
        coverMediaFormat ?? effectiveCoverPage?.mediaFormat;
    final effectiveCoverAnimatedHint =
        coverAnimatedHint || (effectiveCoverPage?.animatedHint ?? false);
    final identityHash = _stableHash(normalizedDirectory);
    final pageRevisionSeed = pages
        .map(
          (page) => '${page.pageId ?? ''}\u0000${page.sourceId}'
              '\u0000${page.contentKindHint.name}'
              '\u0000${page.mediaFormat ?? ''}'
              '\u0000${page.byteLength ?? -1}'
              '\u0000${page.animatedHint}',
        )
        .join('\u0001');
    // Preserve the historical revision for the common first-page-cover case.
    // A separate cover artifact becomes part of the source revision because a
    // cover-only replacement must invalidate the persisted Home projection.
    final revisionSeed = effectiveCover == pages.first.sourceId
        ? pageRevisionSeed
        : 'cover\u0000$effectiveCover\u0000${effectiveCoverMediaFormat ?? ''}'
            '\u0000$effectiveCoverAnimatedHint\u0001$pageRevisionSeed';
    final revisionHash = _stableHash(revisionSeed);
    return ImportedChapterRecord(
      directoryId: normalizedDirectory,
      displayName: normalizedName,
      sourceId: 'local-folder',
      comicId: 'local-$identityHash',
      chapterId: 'folder-$identityHash',
      sourceRevision: 'folder-$revisionHash',
      pages: pages,
      comicTitle: normalizedName,
      coverSourceId: effectiveCover,
      coverMediaFormat: effectiveCoverMediaFormat,
      coverAnimatedHint: effectiveCoverAnimatedHint,
      readingDirection: readingDirection,
      importedAt: importedAt,
    );
  }

  final String directoryId;
  final String displayName;
  final String sourceId;
  final String comicId;
  final String chapterId;
  final String sourceRevision;
  final String comicTitle;
  final List<String> comicAuthors;
  final List<String> comicTags;
  final String? comicDescription;
  final String? coverSourceId;
  final String? coverMediaFormat;
  final bool coverAnimatedHint;
  final bool directoryRecursive;
  final int sequence;
  final List<ImportedPageRecord> pages;
  final ReadingDirection readingDirection;
  final DateTime? sourceUpdatedAt;
  final DateTime importedAt;

  // Both the record and its manifest are immutable. Reuse the metadata
  // projection while this record lives; copyWith creates a fresh projection.
  late final ChapterManifest _manifest = _buildManifest();

  ImportedChapterRecord copyWith({
    String? directoryId,
    String? displayName,
    String? sourceId,
    String? comicId,
    String? comicTitle,
    Iterable<String>? comicAuthors,
    Iterable<String>? comicTags,
    String? comicDescription,
    bool clearComicDescription = false,
    String? coverSourceId,
    bool clearCoverSourceId = false,
    String? coverMediaFormat,
    bool clearCoverMediaFormat = false,
    bool? coverAnimatedHint,
    bool? directoryRecursive,
    String? chapterId,
    String? sourceRevision,
    int? sequence,
    List<ImportedPageRecord>? pages,
    ReadingDirection? readingDirection,
    DateTime? sourceUpdatedAt,
    bool clearSourceUpdatedAt = false,
    DateTime? importedAt,
  }) {
    return ImportedChapterRecord(
      directoryId: directoryId ?? this.directoryId,
      displayName: displayName ?? this.displayName,
      sourceId: sourceId ?? this.sourceId,
      comicId: comicId ?? this.comicId,
      comicTitle: comicTitle ?? this.comicTitle,
      comicAuthors: comicAuthors ?? this.comicAuthors,
      comicTags: comicTags ?? this.comicTags,
      comicDescription: clearComicDescription
          ? null
          : (comicDescription ?? this.comicDescription),
      coverSourceId:
          clearCoverSourceId ? null : (coverSourceId ?? this.coverSourceId),
      coverMediaFormat: clearCoverMediaFormat
          ? null
          : (coverMediaFormat ?? this.coverMediaFormat),
      coverAnimatedHint: coverAnimatedHint ?? this.coverAnimatedHint,
      directoryRecursive: directoryRecursive ?? this.directoryRecursive,
      chapterId: chapterId ?? this.chapterId,
      sourceRevision: sourceRevision ?? this.sourceRevision,
      sequence: sequence ?? this.sequence,
      pages: pages ?? this.pages,
      readingDirection: readingDirection ?? this.readingDirection,
      sourceUpdatedAt: clearSourceUpdatedAt
          ? null
          : (sourceUpdatedAt ?? this.sourceUpdatedAt),
      importedAt: importedAt ?? this.importedAt,
    );
  }

  ChapterManifest toManifest() => _manifest;

  ChapterManifest _buildManifest() {
    final assets = <PageAsset>[];
    for (var index = 0; index < pages.length; index++) {
      final page = pages[index];
      assets.add(
        PageAsset(
          pageId: page.stablePageId,
          chapterId: chapterId,
          index: index,
          uri: page.uri,
          byteLength: page.byteLength,
          checksum: page.checksum,
          checksumAlgorithm: page.checksumAlgorithm,
          contentKindHint: page.contentKindHint,
          animatedHint: page.animatedHint,
        ),
      );
    }
    return ChapterManifest(
      sourceId: sourceId,
      comicId: comicId,
      chapter: Chapter(
        chapterId: chapterId,
        comicId: comicId,
        title: displayName,
        sequence: sequence,
        pageCount: assets.length,
        sourceRevision: sourceRevision,
        updatedAt: sourceUpdatedAt,
      ),
      pages: assets,
      readingDirection: readingDirection,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'directoryId': directoryId,
        if (!directoryRecursive) 'directoryRecursive': false,
        'displayName': displayName,
        'sourceId': sourceId,
        'comicId': comicId,
        'chapterId': chapterId,
        'sourceRevision': sourceRevision,
        'comicTitle': comicTitle,
        'comicAuthors': comicAuthors,
        'comicTags': comicTags,
        if (comicDescription != null) 'comicDescription': comicDescription,
        if (coverSourceId != null) 'coverSourceId': coverSourceId,
        if (coverMediaFormat != null) 'coverMediaFormat': coverMediaFormat,
        'coverAnimatedHint': coverAnimatedHint,
        'sequence': sequence,
        'readingDirection': readingDirection.name,
        if (sourceUpdatedAt != null)
          'sourceUpdatedAt': sourceUpdatedAt!.toUtc().toIso8601String(),
        'importedAt': importedAt.toIso8601String(),
        'pages': pages.map((page) => page.toJson()).toList(growable: false),
      };

  factory ImportedChapterRecord.fromJson(Map<String, Object?> json) {
    final rawPages = json['pages'];
    if (rawPages is! List<Object?>) {
      throw const FormatException('pages must be a list');
    }
    final rawComicTitle = json['comicTitle'];
    if (rawComicTitle != null &&
        (rawComicTitle is! String || rawComicTitle.trim().isEmpty)) {
      throw const FormatException('comicTitle must be a non-empty string');
    }
    final rawAuthors = json['comicAuthors'];
    if (rawAuthors != null &&
        (rawAuthors is! List<Object?> ||
            rawAuthors.any((author) => author is! String))) {
      throw const FormatException('comicAuthors must be a string list');
    }
    final rawTags = json['comicTags'];
    if (rawTags != null &&
        (rawTags is! List<Object?> || rawTags.any((tag) => tag is! String))) {
      throw const FormatException('comicTags must be a string list');
    }
    final rawDescription = json['comicDescription'];
    if (rawDescription != null &&
        (rawDescription is! String || rawDescription.trim().isEmpty)) {
      throw const FormatException(
        'comicDescription must be a non-empty string',
      );
    }
    final rawCoverSourceId = json['coverSourceId'];
    if (rawCoverSourceId != null &&
        (rawCoverSourceId is! String || rawCoverSourceId.trim().isEmpty)) {
      throw const FormatException(
        'coverSourceId must be a non-empty string',
      );
    }
    final rawCoverMediaFormat = json['coverMediaFormat'];
    if (rawCoverMediaFormat != null &&
        (rawCoverMediaFormat is! String || rawCoverMediaFormat.trim().isEmpty)) {
      throw const FormatException(
        'coverMediaFormat must be a non-empty string',
      );
    }
    final rawCoverAnimatedHint = json['coverAnimatedHint'];
    if (rawCoverAnimatedHint != null && rawCoverAnimatedHint is! bool) {
      throw const FormatException('coverAnimatedHint must be a boolean');
    }
    final rawSequence = json['sequence'];
    final rawDirectoryRecursive = json['directoryRecursive'];
    if (rawDirectoryRecursive != null && rawDirectoryRecursive is! bool) {
      throw const FormatException('directoryRecursive must be a boolean');
    }
    if (rawSequence != null && rawSequence is! int) {
      throw const FormatException('sequence must be an integer');
    }
    final parsedPages = rawPages.map((value) {
      if (value is! Map) {
        throw const FormatException('page entry must be an object');
      }
      return ImportedPageRecord.fromJson(Map<String, Object?>.from(value));
    }).toList(growable: false);
    ImportedPageRecord? legacyCoverPage;
    if (rawCoverSourceId is String) {
      for (final page in parsedPages) {
        if (page.sourceId == rawCoverSourceId) {
          legacyCoverPage = page;
          break;
        }
      }
    }
    return ImportedChapterRecord(
      directoryId: _requiredString(json, 'directoryId'),
      directoryRecursive: (rawDirectoryRecursive as bool?) ?? true,
      displayName: _requiredString(json, 'displayName'),
      sourceId: _requiredString(json, 'sourceId'),
      comicId: _requiredString(json, 'comicId'),
      chapterId: _requiredString(json, 'chapterId'),
      sourceRevision: _requiredString(json, 'sourceRevision'),
      comicTitle: (rawComicTitle as String?) ??
          _requiredString(json, 'displayName'),
      comicAuthors: (rawAuthors as List<Object?>?)?.cast<String>() ??
          const <String>[],
      comicTags: (rawTags as List<Object?>?)?.cast<String>() ??
          const <String>[],
      comicDescription: rawDescription as String?,
      coverSourceId: rawCoverSourceId as String?,
      coverMediaFormat:
          (rawCoverMediaFormat as String?) ?? legacyCoverPage?.mediaFormat,
      coverAnimatedHint: (rawCoverAnimatedHint as bool?) ??
          legacyCoverPage?.animatedHint ??
          false,
      sequence: (rawSequence as int?) ?? 0,
      pages: parsedPages,
      readingDirection: ReadingDirection.values.byName(
        (json['readingDirection'] as String?) ?? ReadingDirection.ltr.name,
      ),
      sourceUpdatedAt: json['sourceUpdatedAt'] == null
          ? null
          : DateTime.parse(json['sourceUpdatedAt']! as String),
      importedAt: DateTime.parse(_requiredString(json, 'importedAt')),
    );
  }
}

String _remoteDisplayName(PageAsset page) {
  final segment = page.uri.pathSegments.isEmpty
      ? ''
      : page.uri.pathSegments.last.trim();
  return segment.isEmpty ? 'page-${page.index + 1}' : segment;
}

bool _looksLikeWindowsPath(String value) {
  if (value.startsWith(r'\\')) {
    return true;
  }
  return value.length >= 3 &&
      ((value.codeUnitAt(0) >= 0x41 && value.codeUnitAt(0) <= 0x5a) ||
          (value.codeUnitAt(0) >= 0x61 && value.codeUnitAt(0) <= 0x7a)) &&
      value.codeUnitAt(1) == 0x3a &&
      (value.codeUnitAt(2) == 0x5c || value.codeUnitAt(2) == 0x2f);
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}

String _stableHash(String value) {
  var hash = 0xcbf29ce484222325;
  for (final codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

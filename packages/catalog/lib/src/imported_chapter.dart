import 'package:domain/domain.dart';

final class ImportedPageRecord {
  const ImportedPageRecord({
    required this.displayName,
    required this.sourceId,
    required this.contentKindHint,
    this.pageId,
    this.mediaFormat,
    this.byteLength,
    this.animatedHint = false,
  });

  final String displayName;
  final String sourceId;
  final ContentKindHint contentKindHint;
  final String? pageId;
  final String? mediaFormat;
  final int? byteLength;
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
    this.coverSourceId,
    this.sequence = 0,
    this.readingDirection = ReadingDirection.ltr,
    DateTime? importedAt,
  })  : comicTitle = (comicTitle ?? displayName).trim(),
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
    if (pages.isEmpty) {
      throw ArgumentError.value(pages, 'pages', 'must not be empty');
    }
    final sources = <String>{};
    final pageIds = <String>{};
    for (final page in pages) {
      if (page.displayName.trim().isEmpty || page.sourceId.trim().isEmpty) {
        throw ArgumentError('imported page identity must be non-empty');
      }
      if (page.pageId != null &&
          (page.pageId!.trim().isEmpty || !pageIds.add(page.pageId!))) {
        throw ArgumentError.value(
          page.pageId,
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
      if (!sources.add(page.sourceId)) {
        throw ArgumentError.value(
          page.sourceId,
          'pages',
          'contains a duplicate source identity',
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
      coverSourceId: comic.coverUri?.toString(),
      chapterId: manifest.chapter.chapterId,
      sourceRevision: manifest.chapter.sourceRevision,
      sequence: manifest.chapter.sequence,
      readingDirection: manifest.readingDirection,
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
    ReadingDirection readingDirection = ReadingDirection.ltr,
    DateTime? importedAt,
  }) {
    final normalizedDirectory = directoryId.trim();
    final normalizedName = displayName.trim();
    if (normalizedDirectory.isEmpty || normalizedName.isEmpty) {
      throw ArgumentError('directoryId and displayName must be non-empty');
    }
    final identityHash = _stableHash(normalizedDirectory);
    final revisionHash = _stableHash(
      pages
          .map(
            (page) => '${page.pageId ?? ''}\u0000${page.sourceId}'
                '\u0000${page.contentKindHint.name}'
                '\u0000${page.mediaFormat ?? ''}'
                '\u0000${page.byteLength ?? -1}'
                '\u0000${page.animatedHint}',
          )
          .join('\u0001'),
    );
    return ImportedChapterRecord(
      directoryId: normalizedDirectory,
      displayName: normalizedName,
      sourceId: 'local-folder',
      comicId: 'local-$identityHash',
      chapterId: 'folder-$identityHash',
      sourceRevision: 'folder-$revisionHash',
      pages: pages,
      comicTitle: normalizedName,
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
  final String? coverSourceId;
  final int sequence;
  final List<ImportedPageRecord> pages;
  final ReadingDirection readingDirection;
  final DateTime importedAt;

  ImportedChapterRecord copyWith({
    String? directoryId,
    String? displayName,
    String? sourceId,
    String? comicId,
    String? comicTitle,
    String? coverSourceId,
    bool clearCoverSourceId = false,
    String? chapterId,
    String? sourceRevision,
    int? sequence,
    List<ImportedPageRecord>? pages,
    ReadingDirection? readingDirection,
    DateTime? importedAt,
  }) {
    return ImportedChapterRecord(
      directoryId: directoryId ?? this.directoryId,
      displayName: displayName ?? this.displayName,
      sourceId: sourceId ?? this.sourceId,
      comicId: comicId ?? this.comicId,
      comicTitle: comicTitle ?? this.comicTitle,
      coverSourceId:
          clearCoverSourceId ? null : (coverSourceId ?? this.coverSourceId),
      chapterId: chapterId ?? this.chapterId,
      sourceRevision: sourceRevision ?? this.sourceRevision,
      sequence: sequence ?? this.sequence,
      pages: pages ?? this.pages,
      readingDirection: readingDirection ?? this.readingDirection,
      importedAt: importedAt ?? this.importedAt,
    );
  }

  ChapterManifest toManifest() {
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
      ),
      pages: assets,
      readingDirection: readingDirection,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'directoryId': directoryId,
        'displayName': displayName,
        'sourceId': sourceId,
        'comicId': comicId,
        'chapterId': chapterId,
        'sourceRevision': sourceRevision,
        'comicTitle': comicTitle,
        if (coverSourceId != null) 'coverSourceId': coverSourceId,
        'sequence': sequence,
        'readingDirection': readingDirection.name,
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
    final rawCoverSourceId = json['coverSourceId'];
    if (rawCoverSourceId != null &&
        (rawCoverSourceId is! String || rawCoverSourceId.trim().isEmpty)) {
      throw const FormatException(
        'coverSourceId must be a non-empty string',
      );
    }
    final rawSequence = json['sequence'];
    if (rawSequence != null && rawSequence is! int) {
      throw const FormatException('sequence must be an integer');
    }
    return ImportedChapterRecord(
      directoryId: _requiredString(json, 'directoryId'),
      displayName: _requiredString(json, 'displayName'),
      sourceId: _requiredString(json, 'sourceId'),
      comicId: _requiredString(json, 'comicId'),
      chapterId: _requiredString(json, 'chapterId'),
      sourceRevision: _requiredString(json, 'sourceRevision'),
      comicTitle: (rawComicTitle as String?) ??
          _requiredString(json, 'displayName'),
      coverSourceId: rawCoverSourceId as String?,
      sequence: (rawSequence as int?) ?? 0,
      pages: rawPages.map((value) {
        if (value is! Map) {
          throw const FormatException('page entry must be an object');
        }
        return ImportedPageRecord.fromJson(Map<String, Object?>.from(value));
      }).toList(growable: false),
      readingDirection: ReadingDirection.values.byName(
        (json['readingDirection'] as String?) ?? ReadingDirection.ltr.name,
      ),
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

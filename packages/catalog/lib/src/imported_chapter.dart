import 'package:domain/domain.dart';

final class ImportedPageRecord {
  const ImportedPageRecord({
    required this.displayName,
    required this.sourceId,
    required this.contentKindHint,
    this.mediaFormat,
    this.byteLength,
    this.animatedHint = false,
  });

  final String displayName;
  final String sourceId;
  final ContentKindHint contentKindHint;
  final String? mediaFormat;
  final int? byteLength;
  final bool animatedHint;

  String get stablePageId => 'page-${_stableHash(sourceId)}';

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
        if (mediaFormat != null) 'mediaFormat': mediaFormat,
        if (byteLength != null) 'byteLength': byteLength,
        'animatedHint': animatedHint,
      };

  factory ImportedPageRecord.fromJson(Map<String, Object?> json) {
    final displayName = _requiredString(json, 'displayName');
    final sourceId = _requiredString(json, 'sourceId');
    final kindName = _requiredString(json, 'contentKindHint');
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
    this.readingDirection = ReadingDirection.ltr,
    DateTime? importedAt,
  })  : pages = List<ImportedPageRecord>.unmodifiable(pages),
        importedAt = (importedAt ?? DateTime.now()).toUtc() {
    if (directoryId.trim().isEmpty ||
        displayName.trim().isEmpty ||
        sourceId.trim().isEmpty ||
        comicId.trim().isEmpty ||
        chapterId.trim().isEmpty ||
        sourceRevision.trim().isEmpty) {
      throw ArgumentError('imported chapter identities must be non-empty');
    }
    if (pages.isEmpty) {
      throw ArgumentError.value(pages, 'pages', 'must not be empty');
    }
    final sources = <String>{};
    for (final page in pages) {
      if (page.displayName.trim().isEmpty || page.sourceId.trim().isEmpty) {
        throw ArgumentError('imported page identity must be non-empty');
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
            (page) => '${page.sourceId}\u0000${page.contentKindHint.name}'
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
  final List<ImportedPageRecord> pages;
  final ReadingDirection readingDirection;
  final DateTime importedAt;

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
        sequence: 0,
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
        'readingDirection': readingDirection.name,
        'importedAt': importedAt.toIso8601String(),
        'pages': pages.map((page) => page.toJson()).toList(growable: false),
      };

  factory ImportedChapterRecord.fromJson(Map<String, Object?> json) {
    final rawPages = json['pages'];
    if (rawPages is! List<Object?>) {
      throw const FormatException('pages must be a list');
    }
    return ImportedChapterRecord(
      directoryId: _requiredString(json, 'directoryId'),
      displayName: _requiredString(json, 'displayName'),
      sourceId: _requiredString(json, 'sourceId'),
      comicId: _requiredString(json, 'comicId'),
      chapterId: _requiredString(json, 'chapterId'),
      sourceRevision: _requiredString(json, 'sourceRevision'),
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

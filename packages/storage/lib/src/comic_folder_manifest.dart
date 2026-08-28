import 'dart:convert';

/// Filename of the self-describing comic metadata manifest stored in each
/// downloaded comic directory.
const String comicManifestFileName = '.zic.json';

/// Version tag for [ComicFolderManifest] serialization format.
const String comicManifestFormatV1 = 'zic-comic-v1';

/// Sanitizes a string for use as a filesystem directory or file name across
/// POSIX, Windows, and Android FAT32/exFAT/ext4 filesystems.
String sanitizePathSegment(
  String input, {
  String fallback = 'untitled',
  int maxLength = 60,
}) {
  var sanitized = input
      .replaceAll(RegExp(r'[\/\\:\*\?"<>\|\x00-\x1F\x7F]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  // Strip leading and trailing dots which can be hidden or illegal on Windows/FAT32.
  sanitized = sanitized.replaceAll(RegExp(r'^\.+|\.+$'), '').trim();

  if (sanitized.isEmpty) {
    sanitized = fallback;
  }
  if (sanitized.length > maxLength) {
    sanitized = sanitized.substring(0, maxLength).trim();
  }
  return sanitized.isEmpty ? fallback : sanitized;
}

/// Generates a clean comic folder directory name.
///
/// Uses pure comic title when [conflictSourceSuffix] is null or empty.
/// When [conflictSourceSuffix] is provided to disambiguate identical titles,
/// appends ` (suffix)`.
String buildComicDirectoryName({
  required String comicTitle,
  String? conflictSourceSuffix,
}) {
  final cleanTitle = sanitizePathSegment(comicTitle, fallback: 'comic');
  if (conflictSourceSuffix == null || conflictSourceSuffix.trim().isEmpty) {
    return cleanTitle;
  }
  final cleanSuffix = sanitizePathSegment(
    conflictSourceSuffix,
    fallback: 'source',
  );
  return '$cleanTitle ($cleanSuffix)';
}

/// Generates a clean chapter folder directory name.
String buildChapterDirectoryName(
  String chapterTitle, {
  int fallbackIndex = 1,
}) {
  final clean = sanitizePathSegment(
    chapterTitle,
    fallback: 'chapter_$fallbackIndex',
  );
  return clean;
}

/// Generates a formatted page image filename, e.g. `001.webp`.
String buildPageFileName({
  required int pageIndex,
  required String extension,
}) {
  final cleanExt = sanitizePathSegment(extension, fallback: 'bin')
      .replaceAll('.', '')
      .toLowerCase();
  final padded = pageIndex.toString().padLeft(3, '0');
  return '$padded.$cleanExt';
}

/// Builds the relative path for a page within a comic download tree.
/// If [isSingleChapter] is true, places pages directly under comic folder:
///   `<comicDir>/<pageFileName>`
/// If [isSingleChapter] is false, places pages in chapter subfolder:
///   `<comicDir>/<chapterDir>/<pageFileName>`
String buildPageRelativePath({
  required String comicTitle,
  String? conflictSourceSuffix,
  required String chapterTitle,
  int sequence = 1,
  required int pageIndex,
  required String extension,
  bool isSingleChapter = false,
}) {
  final comicDir = buildComicDirectoryName(
    comicTitle: comicTitle,
    conflictSourceSuffix: conflictSourceSuffix,
  );
  final pageFileName = buildPageFileName(
    pageIndex: pageIndex,
    extension: extension,
  );
  if (isSingleChapter) {
    return '$comicDir/$pageFileName';
  }
  final chapterDir = buildChapterDirectoryName(
    chapterTitle,
    fallbackIndex: sequence,
  );
  return '$comicDir/$chapterDir/$pageFileName';
}

/// Returns true if [folderName] already ends with or includes `(sourceName)`,
/// allowing the UI to avoid duplicate badges like `[拷贝漫画] 航海王 (拷贝漫画)`.
bool hasSourceSuffixInFolderName(String folderName, String sourceName) {
  final cleanFolder = folderName.trim().toLowerCase();
  final cleanSource = sourceName.trim().toLowerCase();
  if (cleanSource.isEmpty) return false;
  return cleanFolder.endsWith('($cleanSource)') ||
      cleanFolder.endsWith('($cleanSource)/') ||
      cleanFolder.contains('($cleanSource)');
}

/// Self-describing metadata manifest written to `.zic.json` inside each
/// downloaded comic directory.
final class ComicFolderManifest {
  const ComicFolderManifest({
    this.format = comicManifestFormatV1,
    required this.sourceId,
    this.sourceDisplayName,
    required this.comicId,
    required this.comicTitle,
    this.chapters = const <String>[],
    required this.updatedAt,
  });

  final String format;
  final String sourceId;
  final String? sourceDisplayName;
  final String comicId;
  final String comicTitle;
  final List<String> chapters;
  final DateTime updatedAt;

  bool get isSingleChapter => chapters.length <= 1;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'format': format,
        'sourceId': sourceId,
        if (sourceDisplayName != null)
          'sourceDisplayName': sourceDisplayName,
        'comicId': comicId,
        'comicTitle': comicTitle,
        if (chapters.isNotEmpty)
          'chapters': chapters,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  factory ComicFolderManifest.fromJson(Map<String, dynamic> json) {
    return ComicFolderManifest(
      format: (json['format'] as String?) ?? comicManifestFormatV1,
      sourceId: (json['sourceId'] as String?) ?? '',
      sourceDisplayName: json['sourceDisplayName'] as String?,
      comicId: (json['comicId'] as String?) ?? '',
      comicTitle: (json['comicTitle'] as String?) ?? '',
      chapters: (json['chapters'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList(growable: false) ??
          const <String>[],
      updatedAt: json['updatedAt'] is String
          ? DateTime.tryParse(json['updatedAt'] as String)?.toUtc() ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
          : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  static ComicFolderManifest? decode(String content) {
    try {
      final map = jsonDecode(content);
      if (map is Map<String, dynamic>) {
        return ComicFolderManifest.fromJson(map);
      }
      if (map is Map) {
        return ComicFolderManifest.fromJson(
          map.cast<String, dynamic>(),
        );
      }
    } on Object {
      // Ignored on corrupt JSON.
    }
    return null;
  }
}

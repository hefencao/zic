import 'dart:convert';
import 'dart:isolate';

import 'download_placement.dart';
import 'comic_folder_file_list.dart';

/// Filename of the self-describing comic metadata manifest stored in each
/// downloaded comic directory.
const String comicManifestFileName = '.zic.json';

/// Version tag for [ComicFolderManifest] serialization format.
const String comicManifestFormatV1 = 'zic-comic-v1';
const String comicManifestFormatV2 = 'zic-comic-v2';

typedef DecodedComicFolderManifest = ({
  ComicFolderManifest? manifest, bool fingerprintValid,
});

typedef PreparedComicFolderManifest = ({
  ComicFolderManifest manifest, String encoded,
});

// These callables capture values only, never the storage owner or its locks.
// The caller keeps commit/recovery authority and awaits physical worker exit.
final class _DecodeComicFolderManifest {
  const _DecodeComicFolderManifest(this.content);
  final String content;

  DecodedComicFolderManifest call() {
    final manifest = ComicFolderManifest.decode(content);
    return (manifest: manifest, fingerprintValid: manifest?.fingerprintValid ?? false);
  }
}

final class _PrepareComicFolderManifest {
  const _PrepareComicFolderManifest(this.draft);
  final ComicFolderManifest draft;

  PreparedComicFolderManifest call() {
    final manifest = draft.copyWith(fingerprint: draft.computedFingerprint);
    return (manifest: manifest, encoded: manifest.encode());
  }
}

Future<DecodedComicFolderManifest> decodeComicFolderManifestAsync(String content) =>
    Isolate.run(_DecodeComicFolderManifest(content).call);

Future<PreparedComicFolderManifest> prepareComicFolderManifestAsync(
  ComicFolderManifest draft,
) => Isolate.run(_PrepareComicFolderManifest(draft).call);

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

/// Parses the 1-based page number from an image filename like `001.webp`, `1.jpg`, `page_001.png`.
/// Returns null if the filename does not represent a valid page image.
int? parsePageIndexFromFileName(String fileName) {
  var name = fileName;
  final lastSlash = name.lastIndexOf('/');
  if (lastSlash >= 0) {
    name = name.substring(lastSlash + 1);
  }
  final lastBackslash = name.lastIndexOf(r'\');
  if (lastBackslash >= 0) {
    name = name.substring(lastBackslash + 1);
  }
  final lastDot = name.lastIndexOf('.');
  if (lastDot <= 0) return null;
  final ext = name.substring(lastDot + 1).toLowerCase();
  const validExtensions = {'webp', 'jpg', 'jpeg', 'png', 'gif', 'avif', 'bin'};
  if (!validExtensions.contains(ext)) return null;

  final base = name.substring(0, lastDot);
  final digitMatch = RegExp(r'^(?:page_?|p)?(\d+)$', caseSensitive: false).firstMatch(base);
  if (digitMatch != null) {
    return int.tryParse(digitMatch.group(1)!);
  }
  final prefixMatch = RegExp(r'^(\d+)[_\s\-]').firstMatch(base);
  if (prefixMatch != null) {
    return int.tryParse(prefixMatch.group(1)!);
  }
  return null;
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
    this.chapterDirectories = const <String, String>{},
    this.chapterTitles = const <String, String>{},
    this.chapterSequences = const <String, int>{},
    this.chapterFiles = const <String, ComicChapterFileList>{},
    this.generation = 0,
    this.fingerprint,
    this.pageOrder = ComicPageOrder.auto,
    required this.updatedAt,
  });

  final String format;
  final String sourceId;
  final String? sourceDisplayName;
  final String comicId;
  final String comicTitle;
  final List<String> chapters;

  /// Stable chapter-id to export-directory mapping. Older manifests omit this
  /// data and continue to use the title-derived directory convention.
  final Map<String, String> chapterDirectories;
  final Map<String, String> chapterTitles;
  final Map<String, int> chapterSequences;
  final Map<String, ComicChapterFileList> chapterFiles;

  /// Monotonic manifest generation. Writers use it to detect stale export
  /// ownership observations before committing a replacement.
  final int generation;

  /// Fingerprint of manifest ownership/content excluding this field.
  final String? fingerprint;
  final ComicPageOrder pageOrder;
  final DateTime updatedAt;

  bool get isSingleChapter => chapters.length <= 1;

  ComicFolderManifest copyWith({
    String? format,
    String? sourceId,
    String? sourceDisplayName,
    String? comicId,
    String? comicTitle,
    List<String>? chapters,
    Map<String, String>? chapterDirectories,
    Map<String, String>? chapterTitles,
    Map<String, int>? chapterSequences,
    Map<String, ComicChapterFileList>? chapterFiles,
    int? generation,
    String? fingerprint,
    ComicPageOrder? pageOrder,
    DateTime? updatedAt,
  }) {
    return ComicFolderManifest(
      format: format ?? this.format,
      sourceId: sourceId ?? this.sourceId,
      sourceDisplayName: sourceDisplayName ?? this.sourceDisplayName,
      comicId: comicId ?? this.comicId,
      comicTitle: comicTitle ?? this.comicTitle,
      chapters: chapters ?? this.chapters,
      chapterDirectories: chapterDirectories ?? this.chapterDirectories,
      chapterTitles: chapterTitles ?? this.chapterTitles,
      chapterSequences: chapterSequences ?? this.chapterSequences,
      chapterFiles: chapterFiles ?? this.chapterFiles,
      generation: generation ?? this.generation,
      fingerprint: fingerprint ?? this.fingerprint,
      pageOrder: pageOrder ?? this.pageOrder,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'format': format,
        'sourceId': sourceId,
        if (sourceDisplayName != null)
          'sourceDisplayName': sourceDisplayName,
        'comicId': comicId,
        'comicTitle': comicTitle,
        if (chapters.isNotEmpty) 'chapters': chapters,
        if (chapterDirectories.isNotEmpty)
          'chapterDirectories': chapterDirectories,
        if (chapterTitles.isNotEmpty) 'chapterTitles': chapterTitles,
        if (chapterSequences.isNotEmpty)
          'chapterSequences': chapterSequences,
        if (chapterFiles.isNotEmpty) 'chapterFiles': {
          for (final chapter in chapterFiles.entries)
            chapter.key: chapter.value.toJson(),
        },
        'generation': generation,
        if (fingerprint != null) 'fingerprint': fingerprint,
        if (pageOrder != ComicPageOrder.auto) 'pageOrder': pageOrder.name,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  factory ComicFolderManifest.fromJson(Map<String, dynamic> json) {
    final orderName = json['pageOrder'] as String?;
    final pageOrder = ComicPageOrder.values.firstWhere(
      (p) => p.name == orderName,
      orElse: () => ComicPageOrder.auto,
    );
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
      chapterDirectories: _stringMap(json['chapterDirectories']),
      chapterTitles: _stringMap(json['chapterTitles']),
      chapterSequences: _intMap(json['chapterSequences']),
      chapterFiles: _chapterFiles(json['chapterFiles']),
      generation: (json['generation'] as num?)?.toInt() ?? 0,
      fingerprint: json['fingerprint'] as String?,
      pageOrder: pageOrder,
      updatedAt: json['updatedAt'] is String
          ? DateTime.tryParse(json['updatedAt'] as String)?.toUtc() ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
          : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  /// Fingerprint calculated from the serialized manifest without the stored
  /// fingerprint field. It is stable across map iteration and can be used as
  /// a compare-and-swap token for the export directory owner.
  String get computedFingerprint {
    final value = Map<String, dynamic>.from(toJson())..remove('fingerprint');
    var hash = 0xcbf29ce4;
    for (final byte in utf8.encode(jsonEncode(_canonicalizeJson(value)))) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  bool get fingerprintValid =>
      fingerprint == null || fingerprint == computedFingerprint;

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

Object? _canonicalizeJson(Object? value) {
  if (value is Map) {
    final entries = <String, Object?>{
      for (final entry in value.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
    final keys = entries.keys.toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalizeJson(entries[key]),
    };
  }
  if (value is List) {
    return value.map(_canonicalizeJson).toList(growable: false);
  }
  return value;
}

Map<String, String> _stringMap(Object? value) {
  if (value is! Map) return const <String, String>{};
  return <String, String>{
    for (final entry in value.entries)
      if (entry.key is String && entry.value is String)
        entry.key as String: entry.value as String,
  };
}

Map<String, int> _intMap(Object? value) {
  if (value is! Map) return const <String, int>{};
  return <String, int>{
    for (final entry in value.entries)
      if (entry.key is String && entry.value is int)
        entry.key as String: entry.value as int,
  };
}

Map<String, ComicChapterFileList> _chapterFiles(Object? value) {
  if (value == null) return const {};
  if (value is! Map<String, dynamic>) {
    throw const FormatException('invalid comic chapter files');
  }
  return {
    for (final entry in value.entries)
      entry.key: ComicChapterFileList.fromJson(
        Map<String, dynamic>.from(entry.value as Map),
      ),
  };
}

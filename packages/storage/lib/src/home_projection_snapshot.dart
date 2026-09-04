import 'dart:convert';
import 'dart:io';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';

const _homeProjectionSnapshotFormat = 'zic-home-projection';
const _legacyHomeProjectionSnapshotVersion = 1;
const _compactHomeProjectionSnapshotVersion = 2;
const _homeProjectionSnapshotVersion = 3;
const _compactPageSourcePrefix = 'zic-home-snapshot-page:';
const _snapshotCompressionThreshold = 512 * 1024;

/// Storage-neutral, read-only download state used only by the Home startup
/// accelerator. The downloads package remains the owner of live task state.
final class HomeChapterDownloadSummary {
  const HomeChapterDownloadSummary({
    required this.sourceId,
    required this.comicId,
    required this.comicTitle,
    required this.chapterId,
    required this.sourceRevision,
    required this.title,
    required this.completedPages,
    required this.totalPages,
    required this.receivedBytes,
    required this.pinnedPages,
    required this.phase,
    required this.started,
    this.totalBytes,
    this.pageProgressUnits,
    this.failure,
  });

  final String sourceId;
  final String comicId;
  final String comicTitle;
  final String chapterId;
  final String sourceRevision;
  final String title;
  final int completedPages;
  final int totalPages;
  final int receivedBytes;
  final int pinnedPages;
  final int? totalBytes;
  final double? pageProgressUnits;
  final String phase;
  final String? failure;
  final bool started;

  Map<String, Object?> toJson() => <String, Object?>{
        'sourceId': sourceId,
        'comicId': comicId,
        'comicTitle': comicTitle,
        'chapterId': chapterId,
        'sourceRevision': sourceRevision,
        'title': title,
        'completedPages': completedPages,
        'totalPages': totalPages,
        'receivedBytes': receivedBytes,
        'pinnedPages': pinnedPages,
        if (totalBytes != null) 'totalBytes': totalBytes,
        if (pageProgressUnits != null)
          'pageProgressUnits': pageProgressUnits,
        'phase': phase,
        if (failure != null) 'failure': failure,
        'started': started,
      };

  factory HomeChapterDownloadSummary.fromJson(Object? value) {
    final json = _requiredMap(value, 'chapter download summary');
    final completedPages = _requiredNonNegativeInt(json, 'completedPages');
    final totalPages = _requiredPositiveInt(json, 'totalPages');
    final pinnedPages = _requiredNonNegativeInt(json, 'pinnedPages');
    if (completedPages > totalPages || pinnedPages > totalPages) {
      throw const FormatException(
        'chapter download page counts exceed totalPages',
      );
    }
    return HomeChapterDownloadSummary(
      sourceId: _requiredString(json, 'sourceId'),
      comicId: _requiredString(json, 'comicId'),
      comicTitle: _requiredString(json, 'comicTitle'),
      chapterId: _requiredString(json, 'chapterId'),
      sourceRevision: _requiredString(json, 'sourceRevision'),
      title: _requiredString(json, 'title'),
      completedPages: completedPages,
      totalPages: totalPages,
      receivedBytes: _requiredNonNegativeInt(json, 'receivedBytes'),
      pinnedPages: pinnedPages,
      totalBytes: _optionalNonNegativeInt(json, 'totalBytes'),
      pageProgressUnits:
          _optionalNonNegativeDouble(json, 'pageProgressUnits'),
      phase: _requiredString(json, 'phase'),
      failure: _optionalLooseString(json, 'failure'),
      started: _requiredBool(json, 'started'),
    );
  }
}

/// The last Home projection that was known to be readable from durable stores.
///
/// This is a startup accelerator only. It is never a source of truth and is
/// deliberately independent from the imported-library schema and WAL files.
final class HomeProjectionSnapshot {
  const HomeProjectionSnapshot({
    required this.entries,
    required this.savedComics,
    required this.categories,
    required this.preferences,
    required this.readStates,
    required this.sourcePreferences,
    required this.versionRelations,
    this.orphanedDownloadEntries = const <ImportedLibraryEntry>[],
    this.chapterDownloads = const <HomeChapterDownloadSummary>[],
    this.libraryRevision,
    this.entriesAreCompact = false,
    this.storedCompressed = true,
    this.includesDownloadProjection = true,
  });

  final List<ImportedLibraryEntry> entries;
  final List<SavedComicRecord> savedComics;
  final List<LibraryCategory> categories;
  final List<ComicPreference> preferences;
  final List<ChapterReadState> readStates;
  final List<ComicSourcePreference> sourcePreferences;
  final List<ComicVersionRelation> versionRelations;
  final List<ImportedLibraryEntry> orphanedDownloadEntries;
  final List<HomeChapterDownloadSummary> chapterDownloads;
  final int? libraryRevision;
  final bool entriesAreCompact;
  final bool storedCompressed;
  final bool includesDownloadProjection;

  /// Legacy, v2, or oversized uncompressed snapshots need one durable rewrite.
  bool get requiresRewrite =>
      !entriesAreCompact || !storedCompressed || !includesDownloadProjection;

  Map<String, Object?> toJson() => <String, Object?>{
        'format': _homeProjectionSnapshotFormat,
        'version': _homeProjectionSnapshotVersion,
        'entries':
            entries.map(_compactEntryToJson).toList(growable: false),
        'savedComics': savedComics.map((comic) => comic.toJson()).toList(),
        'categories': categories.map((category) => category.toJson()).toList(),
        'preferences': preferences.map((preference) => preference.toJson()).toList(),
        'readStates': readStates.map((state) => state.toJson()).toList(),
        'sourcePreferences': sourcePreferences
            .map((preference) => preference.toJson())
            .toList(),
        'versionRelations':
            versionRelations.map(_versionRelationToJson).toList(),
        'orphanedDownloadEntries': orphanedDownloadEntries
            .map(_entryToJson)
            .toList(growable: false),
        'chapterDownloads':
            chapterDownloads.map((summary) => summary.toJson()).toList(),
        if (libraryRevision != null) 'libraryRevision': libraryRevision,
      };

  factory HomeProjectionSnapshot.fromJson(
    Map<String, Object?> json, {
    bool storedCompressed = false,
  }) {
    if (json['format'] != _homeProjectionSnapshotFormat) {
      throw const FormatException('unsupported Home projection snapshot');
    }
    final version = json['version'];
    final entries = _requiredList(json, 'entries');
    final isCompact = version == _compactHomeProjectionSnapshotVersion ||
        version == _homeProjectionSnapshotVersion;
    if (version != _legacyHomeProjectionSnapshotVersion && !isCompact) {
      throw const FormatException('unsupported Home projection snapshot');
    }
    final includesDownloadProjection =
        version == _homeProjectionSnapshotVersion;
    return HomeProjectionSnapshot(
      entries: entries
          .map(isCompact ? _compactEntryFromJson : _entryFromJson)
          .toList(growable: false),
      savedComics: _requiredList(json, 'savedComics')
          .map(_savedComicFromJson)
          .toList(growable: false),
      categories: _requiredList(json, 'categories')
          .map(_categoryFromJson)
          .toList(growable: false),
      preferences: _requiredList(json, 'preferences')
          .map(_preferenceFromJson)
          .toList(growable: false),
      readStates: _requiredList(json, 'readStates')
          .map(_readStateFromJson)
          .toList(growable: false),
      sourcePreferences: _requiredList(json, 'sourcePreferences')
          .map(_sourcePreferenceFromJson)
          .toList(growable: false),
      versionRelations: _requiredList(json, 'versionRelations')
          .map(_versionRelationFromJson)
          .toList(growable: false),
      orphanedDownloadEntries: includesDownloadProjection
          ? _requiredList(json, 'orphanedDownloadEntries')
              .map(_entryFromJson)
              .toList(growable: false)
          : const <ImportedLibraryEntry>[],
      chapterDownloads: includesDownloadProjection
          ? _requiredList(json, 'chapterDownloads')
              .map(HomeChapterDownloadSummary.fromJson)
              .toList(growable: false)
          : const <HomeChapterDownloadSummary>[],
      libraryRevision: _optionalNonNegativeInt(json, 'libraryRevision'),
      entriesAreCompact: isCompact,
      storedCompressed: storedCompressed,
      includesDownloadProjection: includesDownloadProjection,
    );
  }
}

/// File owner for the Home startup snapshot.
///
/// The root provider is lazy so the bootstrap Home can start reading the
/// snapshot before durable SQLite/download services finish opening. Writes
/// are serialized and replace the destination through a temporary file.
final class HomeProjectionSnapshotStore {
  HomeProjectionSnapshotStore({required Future<String> Function() rootProvider})
      : _pathProvider = (() => _homeProjectionSnapshotPath(rootProvider)),
        _fixedPath = null,
        _metadataAlreadyProbed = false;

  factory HomeProjectionSnapshotStore.atPath(
    String path, {
    bool metadataAlreadyProbed = false,
  }) =>
      HomeProjectionSnapshotStore._atPath(
        path,
        metadataAlreadyProbed: metadataAlreadyProbed,
      );

  HomeProjectionSnapshotStore._atPath(
    this._fixedPath, {
    required this._metadataAlreadyProbed,
  }) : _pathProvider = null;

  final Future<String> Function()? _pathProvider;
  final String? _fixedPath;
  final bool _metadataAlreadyProbed;
  Future<String>? _pathFuture;
  Future<void> _writeTail = Future<void>.value();
  Future<HomeProjectionSnapshot?>? _readOperation;
  HomeProjectionSnapshot? _readCache;
  bool _readCacheValid = false;

  Future<String> get _path async {
    final fixedPath = _fixedPath;
    if (fixedPath != null) {
      return fixedPath;
    }
    final existing = _pathFuture;
    if (existing != null) {
      return existing;
    }
    late final Future<String> next;
    next = _resolvePath();
    _pathFuture = next;
    return next;
  }

  Future<String> _resolvePath() async {
    final startedAt = Stopwatch()..start();
    _snapshotLog('home-snapshot-path-resolve-start');
    try {
      final pathProvider = _pathProvider;
      if (pathProvider == null) {
        throw StateError('fixed Home snapshot path was not resolved');
      }
      final path = await pathProvider();
      _snapshotLog(
        'home-snapshot-path-resolve-complete '
        'durationMs=${startedAt.elapsedMilliseconds}',
      );
      return path;
    } on Object catch (error) {
      _snapshotLog(
        'home-snapshot-path-resolve-failed '
        'durationMs=${startedAt.elapsedMilliseconds} '
        'errorType=${error.runtimeType}',
      );
      rethrow;
    }
  }

  /// Returns null for a missing, corrupt, or incompatible snapshot.
  ///
  /// SQLite remains authoritative, so no startup path should fail merely
  /// because this optional accelerator cannot be read.
  Future<HomeProjectionSnapshot?> read() {
    if (_readCacheValid) {
      _snapshotLog(
        'home-snapshot-read-cached present=${_readCache != null}',
      );
      return Future<HomeProjectionSnapshot?>.value(_readCache);
    }
    final existing = _readOperation;
    if (existing != null) {
      _snapshotLog('home-snapshot-read-joined');
      return existing;
    }
    late final Future<HomeProjectionSnapshot?> operation;
    operation = _readFromDisk().then((snapshot) {
      _readCache = snapshot;
      _readCacheValid = true;
      return snapshot;
    }).whenComplete(() {
      if (identical(_readOperation, operation)) {
        _readOperation = null;
      }
    });
    _readOperation = operation;
    return operation;
  }

  Future<HomeProjectionSnapshot?> _readFromDisk() async {
    final startedAt = Stopwatch()..start();
    _snapshotLog('home-snapshot-read-start');
    try {
      final fixedPath = _fixedPath;
      final file = File(fixedPath ?? await _path);
      if (!_metadataAlreadyProbed && !await file.exists()) {
        _snapshotLog(
          'home-snapshot-read-missing '
          'durationMs=${startedAt.elapsedMilliseconds}',
        );
        return null;
      }
      final bytesStartedAt = Stopwatch()..start();
      late final List<int> storedBytes;
      try {
        storedBytes = await file.readAsBytes();
      } on FileSystemException {
        _snapshotLog(
          'home-snapshot-read-missing '
          'durationMs=${startedAt.elapsedMilliseconds}',
        );
        return null;
      }
      final compressed = _isGzip(storedBytes);
      final bytes = compressed ? gzip.decode(storedBytes) : storedBytes;
      _snapshotLog(
        'home-snapshot-bytes-read storedBytes=${storedBytes.length} '
        'jsonBytes=${bytes.length} compressed=$compressed '
        'durationMs=${bytesStartedAt.elapsedMilliseconds}',
      );
      final jsonDecodeStartedAt = Stopwatch()..start();
      final decoded = jsonDecode(utf8.decode(bytes));
      _snapshotLog(
        'home-snapshot-json-decode-complete '
        'durationMs=${jsonDecodeStartedAt.elapsedMilliseconds}',
      );
      if (decoded is! Map) {
        _snapshotLog(
          'home-snapshot-read-invalid-root bytes=${bytes.length} '
          'durationMs=${startedAt.elapsedMilliseconds}',
        );
        return null;
      }
      final modelDecodeStartedAt = Stopwatch()..start();
      final snapshot = HomeProjectionSnapshot.fromJson(
        Map<String, Object?>.from(decoded),
        storedCompressed: compressed ||
            storedBytes.length < _snapshotCompressionThreshold,
      );
      _snapshotLog(
        'home-snapshot-model-decode-complete '
        'durationMs=${modelDecodeStartedAt.elapsedMilliseconds}',
      );
      _snapshotLog(
        'home-snapshot-read-complete bytes=${bytes.length} '
        'entries=${snapshot.entries.length} '
        'saved=${snapshot.savedComics.length} '
        'readStates=${snapshot.readStates.length} '
        'chapterDownloads=${snapshot.chapterDownloads.length} '
        'compact=${snapshot.entriesAreCompact} '
        'revision=${snapshot.libraryRevision ?? 'none'} '
        'durationMs=${startedAt.elapsedMilliseconds}',
      );
      return snapshot;
    } on Object catch (error) {
      _snapshotLog(
        'home-snapshot-read-failed '
        'durationMs=${startedAt.elapsedMilliseconds} '
        'errorType=${error.runtimeType}',
      );
      return null;
    }
  }

  Future<void> write(HomeProjectionSnapshot snapshot) {
    _snapshotLog(
      'home-snapshot-write-queued '
      'entries=${snapshot.entries.length} '
      'saved=${snapshot.savedComics.length} '
      'readStates=${snapshot.readStates.length} '
      'chapterDownloads=${snapshot.chapterDownloads.length} '
      'revision=${snapshot.libraryRevision ?? 'none'}',
    );
    final operation = _writeTail.then<void>((_) async {
      final startedAt = Stopwatch()..start();
      _snapshotLog('home-snapshot-write-start');
      try {
        final fixedPath = _fixedPath;
        final file = File(fixedPath ?? await _path);
        await file.parent.create(recursive: true);
        final temporary = File('${file.path}.tmp');
        final jsonBytes = utf8.encode(jsonEncode(snapshot.toJson()));
        final storedBytes = jsonBytes.length >= _snapshotCompressionThreshold
            ? gzip.encode(jsonBytes)
            : jsonBytes;
        final compressed = storedBytes.length != jsonBytes.length;
        await temporary.writeAsBytes(storedBytes, flush: true);
        try {
          await temporary.rename(file.path);
        } on FileSystemException {
          // Android's rename can reject an existing destination. Keep the
          // replacement recoverable and retry after removing only this file.
          if (await file.exists()) {
            await file.delete();
          }
          await temporary.rename(file.path);
        }
        _snapshotLog(
          'home-snapshot-write-complete storedBytes=${storedBytes.length} '
          'jsonBytes=${jsonBytes.length} compressed=$compressed '
          'durationMs=${startedAt.elapsedMilliseconds}',
        );
        _readCache = null;
        _readCacheValid = false;
      } on Object catch (error) {
        _snapshotLog(
          'home-snapshot-write-failed '
          'durationMs=${startedAt.elapsedMilliseconds} '
          'errorType=${error.runtimeType}',
        );
        rethrow;
      }
    });
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

}

bool _isGzip(List<int> bytes) =>
    bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;

void _snapshotLog(String message) {
  print('[zic-storage] $message');
}

Map<String, Object?> _entryToJson(ImportedLibraryEntry entry) =>
    <String, Object?>{
      'chapter': entry.chapter.toJson(),
      if (entry.progress != null) 'progress': entry.progress!.toJson(),
    };

Map<String, Object?> _compactEntryToJson(ImportedLibraryEntry entry) =>
    <String, Object?>{
      'chapter': _compactChapterToJson(entry.chapter),
      if (entry.progress != null) 'progress': entry.progress!.toJson(),
    };

Map<String, Object?> _compactChapterToJson(ImportedChapterRecord chapter) =>
    <String, Object?>{
      'directoryId': chapter.directoryId,
      'displayName': chapter.displayName,
      'sourceId': chapter.sourceId,
      'comicId': chapter.comicId,
      'chapterId': chapter.chapterId,
      'sourceRevision': chapter.sourceRevision,
      'comicTitle': chapter.comicTitle,
      'comicAuthors': chapter.comicAuthors,
      'comicTags': chapter.comicTags,
      if (chapter.comicDescription != null)
        'comicDescription': chapter.comicDescription,
      if (chapter.coverSourceId != null) 'coverSourceId': chapter.coverSourceId,
      'sequence': chapter.sequence,
      'readingDirection': chapter.readingDirection.name,
      'importedAt': chapter.importedAt.toIso8601String(),
      'pageCount': chapter.pages.length,
    };

ImportedLibraryEntry _entryFromJson(Object? value) {
  final json = _requiredMap(value, 'entry');
  final rawProgress = json['progress'];
  return ImportedLibraryEntry(
    chapter: ImportedChapterRecord.fromJson(
      _requiredMap(json['chapter'], 'chapter'),
    ),
    progress: rawProgress == null
        ? null
        : ReadingProgress.fromJson(_requiredMap(rawProgress, 'progress')),
  );
}

ImportedLibraryEntry _compactEntryFromJson(Object? value) {
  final json = _requiredMap(value, 'entry');
  final rawProgress = json['progress'];
  return ImportedLibraryEntry(
    chapter: _compactChapterFromJson(
      _requiredMap(json['chapter'], 'chapter'),
    ),
    progress: rawProgress == null
        ? null
        : ReadingProgress.fromJson(_requiredMap(rawProgress, 'progress')),
  );
}

ImportedChapterRecord _compactChapterFromJson(Map<String, Object?> json) {
  final displayName = _requiredString(json, 'displayName');
  final pageCount = _requiredPositiveInt(json, 'pageCount');
  final rawComicTitle = json['comicTitle'];
  if (rawComicTitle != null &&
      (rawComicTitle is! String || rawComicTitle.trim().isEmpty)) {
    throw const FormatException('comicTitle must be a non-empty string');
  }
  return ImportedChapterRecord(
    directoryId: _requiredString(json, 'directoryId'),
    displayName: displayName,
    sourceId: _requiredString(json, 'sourceId'),
    comicId: _requiredString(json, 'comicId'),
    chapterId: _requiredString(json, 'chapterId'),
    sourceRevision: _requiredString(json, 'sourceRevision'),
    comicTitle: (rawComicTitle as String?) ?? displayName,
    comicAuthors: _optionalStringList(json, 'comicAuthors'),
    comicTags: _optionalStringList(json, 'comicTags'),
    comicDescription: _optionalString(json, 'comicDescription'),
    coverSourceId: _optionalString(json, 'coverSourceId'),
    sequence: _optionalInteger(json, 'sequence') ?? 0,
    pages: List<ImportedPageRecord>.generate(
      pageCount,
      (index) => ImportedPageRecord(
        displayName: 'page-${index + 1}',
        sourceId: '$_compactPageSourcePrefix$index',
        contentKindHint: ContentKindHint.unknown,
      ),
      growable: false,
    ),
    readingDirection: ReadingDirection.values.byName(
      (json['readingDirection'] as String?) ?? ReadingDirection.ltr.name,
    ),
    importedAt: DateTime.parse(_requiredString(json, 'importedAt')),
  );
}

SavedComicRecord _savedComicFromJson(Object? value) =>
    SavedComicRecord.fromJson(_requiredMap(value, 'saved comic'));

LibraryCategory _categoryFromJson(Object? value) =>
    LibraryCategory.fromJson(_requiredMap(value, 'category'));

ComicPreference _preferenceFromJson(Object? value) =>
    ComicPreference.fromJson(_requiredMap(value, 'comic preference'));

ChapterReadState _readStateFromJson(Object? value) =>
    ChapterReadState.fromJson(_requiredMap(value, 'chapter read state'));

ComicSourcePreference _sourcePreferenceFromJson(Object? value) =>
    ComicSourcePreference.fromJson(_requiredMap(value, 'source preference'));

Map<String, Object?> _versionRelationToJson(ComicVersionRelation relation) =>
    <String, Object?>{
      'sourceId': relation.sourceId,
      'predecessorComicId': relation.predecessorComicId,
      'successorComicId': relation.successorComicId,
      'predecessorTitle': relation.predecessorTitle,
      if (relation.discoveredAt != null)
        'discoveredAt': relation.discoveredAt!.toUtc().toIso8601String(),
      'pageMappings': relation.pageMappings
          .map((mapping) => mapping.toJson())
          .toList(growable: false),
    };

ComicVersionRelation _versionRelationFromJson(Object? value) {
  final json = _requiredMap(value, 'version relation');
  final rawMappings = _requiredList(json, 'pageMappings');
  return ComicVersionRelation(
    sourceId: _requiredString(json, 'sourceId'),
    predecessorComicId: _requiredString(json, 'predecessorComicId'),
    successorComicId: _requiredString(json, 'successorComicId'),
    predecessorTitle: (json['predecessorTitle'] as String?) ?? '',
    discoveredAt: json['discoveredAt'] == null
        ? null
        : DateTime.parse(json['discoveredAt']! as String),
    pageMappings: rawMappings
        .map(
          (mapping) => ComicVersionPageMapping.fromJson(
            _requiredMap(mapping, 'page mapping'),
          ),
        )
        .toList(growable: false),
  );
}

List<Object?> _requiredList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List) {
    throw FormatException('$key must be a list');
  }
  return value.cast<Object?>();
}

Map<String, Object?> _requiredMap(Object? value, String label) {
  if (value is! Map) {
    throw FormatException('$label must be an object');
  }
  return Map<String, Object?>.from(value);
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}

int? _optionalNonNegativeInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! num || value.isNaN || value.isInfinite || value < 0) {
    throw FormatException('$key must be a non-negative integer');
  }
  final integer = value.toInt();
  if (integer.toDouble() != value) {
    throw FormatException('$key must be a non-negative integer');
  }
  return integer;
}

int _requiredNonNegativeInt(Map<String, Object?> json, String key) {
  final value = _optionalNonNegativeInt(json, key);
  if (value == null) {
    throw FormatException('$key must be a non-negative integer');
  }
  return value;
}

int _requiredPositiveInt(Map<String, Object?> json, String key) {
  final value = _optionalNonNegativeInt(json, key);
  if (value == null || value < 1) {
    throw FormatException('$key must be a positive integer');
  }
  return value;
}

double? _optionalNonNegativeDouble(
  Map<String, Object?> json,
  String key,
) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! num || value.isNaN || value.isInfinite || value < 0) {
    throw FormatException('$key must be a non-negative number');
  }
  return value.toDouble();
}

bool _requiredBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) {
    throw FormatException('$key must be a bool');
  }
  return value;
}

int? _optionalInteger(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! num || value.isNaN || value.isInfinite) {
    throw FormatException('$key must be an integer');
  }
  final integer = value.toInt();
  if (integer.toDouble() != value) {
    throw FormatException('$key must be an integer');
  }
  return integer;
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key must be null or a non-empty string');
  }
  return value;
}

String? _optionalLooseString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw FormatException('$key must be null or a string');
  }
  return value;
}

List<String> _optionalStringList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return const <String>[];
  }
  if (value is! List || value.any((item) => item is! String)) {
    throw FormatException('$key must be a string list');
  }
  return value.cast<String>();
}

Future<String> _homeProjectionSnapshotPath(
  Future<String> Function() rootProvider,
) async =>
    '${await rootProvider()}${Platform.pathSeparator}'
    'home_projection_snapshot.json';

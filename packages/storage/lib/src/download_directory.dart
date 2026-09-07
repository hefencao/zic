import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sql;

/// Default chapter-download store directory under the application storage
/// root. The store layout itself is [CacheLayout] (`cache.sqlite`, `partial/`,
/// `final/`) owned by `PersistentDownloadArtifactStore`.
String defaultChapterDownloadDirectory(String storageRoot) {
  final separator = Platform.pathSeparator;
  return '${_stripTrailingSeparator(storageRoot)}${separator}offline_chapters';
}

/// App-private SQLite authority for chapter-download metadata.
///
/// Artifact/partial bytes may live on a user-selected root, but this database
/// deliberately stays under the application support root so changing export
/// roots never requires moving metadata authority with the bytes.
String defaultChapterDownloadMetadataPath(String storageRoot) {
  final separator = Platform.pathSeparator;
  return '${_stripTrailingSeparator(storageRoot)}${separator}chapter_downloads.sqlite';
}

/// Location used by pre-App-private chapter metadata for one configured byte
/// root. SAF historically kept its SQLite index in the default private byte
/// staging directory even though sealed finals were mirrored through SAF.
String legacyChapterDownloadMetadataPath({
  required String storageRoot,
  required String downloadDirectory,
}) {
  final directory = downloadDirectory.startsWith('saf://')
      ? defaultChapterDownloadDirectory(storageRoot)
      : downloadDirectory;
  return '${_stripTrailingSeparator(directory)}${Platform.pathSeparator}cache.sqlite';
}

/// Imports a legacy download-root `cache.sqlite` into App-private metadata.
///
/// SQLite performs the snapshot with `VACUUM INTO`, so committed WAL content is
/// included without copying database sidecars by hand. The legacy files are
/// removed only after the snapshot passes `PRAGMA integrity_check` and has
/// atomically become the destination authority.
Future<bool> migrateLegacyChapterDownloadMetadata({
  required String legacyDbPath,
  required String metadataDbPath,
}) async {
  final legacy = File(legacyDbPath);
  final metadata = File(metadataDbPath);
  if (_comparisonPath(legacy.path) == _comparisonPath(metadata.path) ||
      await metadata.exists() ||
      !await legacy.exists()) {
    return false;
  }
  await metadata.parent.create(recursive: true);
  final temporaryPath = '$metadataDbPath.zic-metadata-migration';
  await _deleteSqliteFileSet(temporaryPath);

  final source = sql.sqlite3.open(legacy.path);
  try {
    final escaped = temporaryPath.replaceAll("'", "''");
    source.execute("VACUUM INTO '$escaped'");
  } finally {
    source.close();
  }

  final migrated = sql.sqlite3.open(temporaryPath);
  try {
    final rows = migrated.select('PRAGMA integrity_check');
    if (rows.length != 1 || rows.single.values.single != 'ok') {
      throw StateError('migrated chapter-download metadata failed integrity_check');
    }
  } finally {
    migrated.close();
  }

  if (await metadata.exists()) {
    // Another startup owner won the same migration race. Keep its authority
    // and discard only this verified temporary snapshot.
    await _deleteSqliteFileSet(temporaryPath);
    return false;
  }
  await File(temporaryPath).rename(metadataDbPath);
  // The App-private snapshot is authoritative now. A legacy root that became
  // read-only after the snapshot must not turn successful adoption into a
  // startup failure; stale sidecars are ignored by all new opens.
  await _deleteSqliteFileSet(legacyDbPath, ignoreErrors: true);
  return true;
}

Future<void> _deleteSqliteFileSet(
  String path, {
  bool ignoreErrors = false,
}) async {
  for (final suffix in const <String>['', '-wal', '-shm', '-journal']) {
    final file = File('$path$suffix');
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      if (!ignoreErrors) rethrow;
    }
  }
}

/// Resolves the effective chapter-download store directory for a user-picked
/// parent directory.
///
/// Old/new-file handling follows the Venera storage-path rules:
///
/// - A missing or empty picked directory is used directly.
/// - A non-empty picked directory is never merged into or clobbered. The
///   store instead lives in the first available `offline_chapters`,
///   `offline_chapters(1)`, ... entry inside it. Existing but empty entries
///   are reused; existing non-empty entries are skipped.
///
/// The returned path is created if it did not exist yet. Set [create] to
/// `false` for read-only previews (settings dialogs): candidates are then
/// resolved without touching the filesystem, so cancelling the dialog never
/// leaves empty `offline_chapters(N)` directories behind.
Future<String> resolveChapterDownloadDirectory(
  String pickedDirectory, {
  String storeName = 'offline_chapters',
  bool create = true,
}) async {
  final parent = Directory(_stripTrailingSeparator(pickedDirectory));
  _rejectDirectoryPathLinks(parent.path);
  final parentType = FileSystemEntity.typeSync(
    parent.path,
    followLinks: false,
  );
  if (parentType == FileSystemEntityType.link) {
    throw StateError(
      'chapter-download directory resolver does not support a symbolic-link parent: '
      '${parent.path}',
    );
  }
  if (parentType != FileSystemEntityType.notFound &&
      parentType != FileSystemEntityType.directory) {
    throw ArgumentError.value(
      pickedDirectory,
      'pickedDirectory',
      'must be a directory',
    );
  }
  if (!parent.existsSync()) {
    if (!create) return parent.path;
    await parent.create(recursive: true);
    return parent.path;
  }
  final content = await parent.list(followLinks: false).toList();
  if (content.isEmpty) {
    return parent.path;
  }
  var index = 0;
  while (true) {
    final candidateName = index == 0 ? storeName : '$storeName($index)';
    final candidate = Directory(
      '${parent.path}${Platform.pathSeparator}$candidateName',
    );
    _rejectDirectoryPathLinks(candidate.path);
    final candidateType = FileSystemEntity.typeSync(
      candidate.path,
      followLinks: false,
    );
    if (candidateType == FileSystemEntityType.link) {
      throw StateError(
        'chapter-download directory resolver does not support a symbolic-link '
        'candidate: ${candidate.path}',
      );
    }
    if (!candidate.existsSync()) {
      if (!create) return candidate.path;
      await candidate.create(recursive: true);
      return candidate.path;
    }
    final candidateContent = await candidate.list(followLinks: false).toList();
    if (candidateContent.isEmpty) {
      return candidate.path;
    }
    index++;
  }
}

/// Probes that [directory] accepts file writes.
///
/// Android scoped storage can allow listing/creating a directory while still
/// denying ordinary file writes; this probe fails fast with the underlying
/// error instead of letting a later store open degrade to memory mode.
Future<void> probeChapterDownloadDirectoryWritable(String directory) async {
  _rejectDirectoryPathLinks(directory);
  final probe = File(
    '${_stripTrailingSeparator(directory)}'
    '${Platform.pathSeparator}.zic-write-probe',
  );
  await probe.writeAsBytes(const <int>[0], flush: true);
  await probe.delete();
}

/// Returns whether [directory] already holds chapter-download store content.
bool chapterDownloadStoreHasContent(String directory) {
  final type = FileSystemEntity.typeSync(directory, followLinks: false);
  if (type == FileSystemEntityType.notFound) return false;
  if (type != FileSystemEntityType.directory) return true;
  final root = Directory(directory);
  // Structured comic directories and `.zic.json` are part of the same store,
  // not disposable export files. A recursive move must therefore treat any
  // non-empty entry as authoritative content, including an interrupted temp
  // marker that needs recovery on the next attempt.
  return root.listSync(followLinks: false).isNotEmpty;
}

/// Result of a completed chapter-download store move.
final class ChapterDownloadStoreMoveReport {
  const ChapterDownloadStoreMoveReport({
    required this.movedFileCount,
    required this.rewrittenRecordCount,
  });

  final int movedFileCount;
  final int rewrittenRecordCount;
}

/// Moves one chapter-download byte store from [from] to [to], rewriting
/// indexed record paths to the new location.
///
/// Legacy callers omit [metadataDbPath] and keep the historical colocated
/// `cache.sqlite` behavior. Production passes the App-private metadata path;
/// the database then stays in place while only artifact/export bytes move.
/// The operation is idempotent so a crashed earlier attempt can be completed
/// by running it again.
///
/// Throws [ArgumentError] when the source has no movable content, both paths
/// are equal, or one path contains the other; moving between nested
/// directories would make the source and target stores ambiguous.
Future<ChapterDownloadStoreMoveReport> moveChapterDownloadStore({
  required String from,
  required String to,
  String? metadataDbPath,
}) async {
  final source = _normalizeDirectoryPath(from);
  final target = _normalizeDirectoryPath(to);
  _rejectDirectoryPathLinks(source);
  _rejectDirectoryPathLinks(target);
  if (isSameOrNestedDirectoryPath(source, target)) {
    throw ArgumentError.value(
      to,
      'to',
      'must not be the download directory itself or inside it',
    );
  }
  final sourceRoot = Directory(source);
  final targetRoot = Directory(target);
  final detachedLegacyMetadataPaths = metadataDbPath == null
      ? const <String>{}
      : <String>{
          '$source${Platform.pathSeparator}cache.sqlite',
          '$source${Platform.pathSeparator}cache.sqlite-wal',
          '$source${Platform.pathSeparator}cache.sqlite-shm',
          '$source${Platform.pathSeparator}cache.sqlite-journal',
        };
  bool isDetachedLegacyMetadata(FileSystemEntity entity) =>
      detachedLegacyMetadataPaths.contains(entity.path);
  final sourceHasContent = _containsStore(source);
  final targetHasContent = _containsStore(target);
  if (!sourceHasContent && !targetHasContent) {
    throw ArgumentError.value(
      from,
      'from',
      'chapter-download store has no movable content',
    );
  }
  if (FileSystemEntity.typeSync(source, followLinks: false) ==
      FileSystemEntityType.link) {
    throw StateError(
      'download-store move does not support a symbolic-link source: $source',
    );
  }
  if (FileSystemEntity.typeSync(target, followLinks: false) ==
      FileSystemEntityType.link) {
    throw StateError(
      'download-store move does not support a symbolic-link target: $target',
    );
  }

  var movedFiles = 0;
  Future<bool> sameFileContents(File first, File second) async {
    if (!await first.exists() || !await second.exists()) return false;
    if (await first.length() != await second.length()) return false;
    final left = await first.open();
    final right = await second.open();
    try {
      while (true) {
        final leftChunk = await left.read(512 * 1024);
        final rightChunk = await right.read(leftChunk.length);
        if (leftChunk.length != rightChunk.length) return false;
        for (var index = 0; index < leftChunk.length; index++) {
          if (leftChunk[index] != rightChunk[index]) return false;
        }
        if (leftChunk.isEmpty) return true;
      }
    } finally {
      await left.close();
      await right.close();
    }
  }

  Future<void> moveFile(File file, File destination) async {
    if (!await file.exists()) return;
    await destination.parent.create(recursive: true);
    if (await destination.exists()) {
      if (await sameFileContents(file, destination)) {
        await file.delete();
        movedFiles++;
        return;
      }
      throw StateError(
        'download-store move found different files at ${destination.path}',
      );
    }
    try {
      await file.rename(destination.path);
    } on FileSystemException {
      final staged = File(
        '${destination.path}.zic-move-tmp-${DateTime.now().microsecondsSinceEpoch}',
      );
      try {
        await file.copy(staged.path);
        await staged.rename(destination.path);
        await file.delete();
      } finally {
        if (await staged.exists()) await staged.delete();
      }
    }
    movedFiles++;
  }

  Future<void> validateTree(
    Directory current,
    Directory destination,
  ) async {
    if (!await current.exists()) return;
    await for (final entity in current.list(followLinks: false)) {
      if (current.path == sourceRoot.path && isDetachedLegacyMetadata(entity)) {
        continue;
      }
      final name = entity.path.substring(current.path.length + 1);
      final destinationPath =
          '${destination.path}${Platform.pathSeparator}$name';
      if (entity is Link) {
        throw StateError(
          'download-store move does not support symbolic links: ${entity.path}',
        );
      }
      if (entity is Directory) {
        final destinationType = FileSystemEntity.typeSync(
          destinationPath,
          followLinks: false,
        );
        if (destinationType == FileSystemEntityType.link) {
          throw StateError(
            'download-store move does not support a symbolic-link target: '
            '$destinationPath',
          );
        }
        if (destinationType != FileSystemEntityType.notFound &&
            destinationType != FileSystemEntityType.directory) {
          throw StateError(
            'download-store move found a file where a directory is required '
            'at $destinationPath',
          );
        }
        await validateTree(entity, Directory(destinationPath));
      } else if (entity is File) {
        final destinationType = FileSystemEntity.typeSync(
          destinationPath,
          followLinks: false,
        );
        if (destinationType == FileSystemEntityType.link) {
          throw StateError(
            'download-store move does not support a symbolic-link target: '
            '$destinationPath',
          );
        }
        if (destinationType != FileSystemEntityType.notFound &&
            destinationType != FileSystemEntityType.file) {
          throw StateError(
            'download-store move found a directory where a file is required '
            'at $destinationPath',
          );
        }
        final destinationFile = File(destinationPath);
        if (await destinationFile.exists() &&
            !await sameFileContents(entity, destinationFile)) {
          throw StateError(
            'download-store move found different files at $destinationPath',
          );
        }
      } else {
        throw StateError(
          'download-store move found unsupported entry: ${entity.path}',
        );
      }
    }
  }

  Future<void> moveTree(Directory current, Directory destination) async {
    if (!await current.exists()) return;
    await destination.create(recursive: true);
    await for (final entity in current.list(followLinks: false)) {
      if (current.path == sourceRoot.path && isDetachedLegacyMetadata(entity)) {
        continue;
      }
      final name = entity.path.substring(current.path.length + 1);
      final targetEntity = '${destination.path}${Platform.pathSeparator}$name';
      if (entity is File) {
        await moveFile(entity, File(targetEntity));
      } else if (entity is Directory) {
        await moveTree(entity, Directory(targetEntity));
        if (await entity.exists() &&
            (await entity.list(followLinks: false).isEmpty)) {
          await entity.delete();
        }
      } else if (entity is Link) {
        // Never silently leave a symlink behind while the index is rewritten.
        // A symlink may point outside the store, so following or copying it
        // would make migration unsafe; retain the pending marker and require
        // an explicit cleanup before retrying.
        throw StateError(
          'download-store move does not support symbolic links: ${entity.path}',
        );
      } else {
        throw StateError(
          'download-store move found unsupported entry: ${entity.path}',
        );
      }
    }
    if (await current.exists() &&
        (await current.list(followLinks: false).isEmpty)) {
      await current.delete();
    }
  }

  if (sourceHasContent) {
    // Validate the whole tree before creating the destination or moving any
    // entry. Unsupported entries and deterministic conflicts therefore leave
    // the pending-move source untouched, allowing startup to reopen it while
    // retaining the retry marker.
    final sourceType = FileSystemEntity.typeSync(
      source,
      followLinks: false,
    );
    if (sourceType != FileSystemEntityType.directory) {
      throw StateError(
        'download-store move source is not a directory: $source',
      );
    }
    final targetType = FileSystemEntity.typeSync(
      target,
      followLinks: false,
    );
    if (targetType != FileSystemEntityType.notFound &&
        targetType != FileSystemEntityType.directory) {
      throw StateError(
        'download-store move target is not a directory: $target',
      );
    }
    await validateTree(sourceRoot, targetRoot);
    await moveTree(sourceRoot, targetRoot);
  }

  final separator = Platform.pathSeparator;
  final rewrittenRecords = _rewriteIndexPaths(
    dbPath: metadataDbPath ??
        '${targetRoot.path}${separator}cache.sqlite',
    oldPrefix: source,
    newPrefix: target,
  );
  if (metadataDbPath != null) {
    await _deleteSqliteFileSet(
      '$source${separator}cache.sqlite',
      ignoreErrors: true,
    );
    if (await sourceRoot.exists() &&
        (await sourceRoot.list(followLinks: false).isEmpty)) {
      await sourceRoot.delete();
    }
  }
  return ChapterDownloadStoreMoveReport(
    movedFileCount: movedFiles,
    rewrittenRecordCount: rewrittenRecords,
  );
}

bool _containsStore(String directory) =>
    chapterDownloadStoreHasContent(directory);

/// Compares two directory paths after removing trailing separators.
bool isSameDirectoryPath(String a, String b) =>
    _comparisonPath(a) == _comparisonPath(b);

/// Returns whether the two paths are equal or one contains the other.
///
/// Moving a download store between nested directories would make the source
/// and target stores ambiguous, so callers refuse this relation up front.
bool isSameOrNestedDirectoryPath(String a, String b) {
  final separator = Platform.pathSeparator;
  final left = _withTrailingSeparator(_comparisonPath(a), separator);
  final right = _withTrailingSeparator(_comparisonPath(b), separator);
  return left == right || right.startsWith(left) || left.startsWith(right);
}

String _comparisonPath(String path) {
  final normalized = _normalizeDirectoryPath(path);
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

String _normalizeDirectoryPath(String path) {
  final absolute = Directory(path).absolute.path;
  final separator = Platform.pathSeparator;
  final prefix = absolute.startsWith(separator) ? separator : '';
  final parts = absolute.split(separator);
  final normalized = <String>[];
  for (final part in parts) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (normalized.isNotEmpty && normalized.last != '..') {
        normalized.removeLast();
      }
      continue;
    }
    normalized.add(part);
  }
  final result = normalized.join(separator);
  if (prefix.isNotEmpty) return '$prefix$result';
  return result.isEmpty ? '.' : result;
}

String _withTrailingSeparator(String path, String separator) =>
    path.endsWith(separator) ? path : '$path$separator';

void _rejectDirectoryPathLinks(String path) {
  if (FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.link) {
    throw StateError(
      'chapter-download directory path contains a symbolic link: $path',
    );
  }
}

String _stripTrailingSeparator(String path) {
  var result = path;
  while (result.length > 1 && result.endsWith(Platform.pathSeparator)) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

int _rewriteIndexPaths({
  required String dbPath,
  required String oldPrefix,
  required String newPrefix,
}) {
  final file = File(dbPath);
  if (!file.existsSync()) return 0;
  final separator = Platform.pathSeparator;
  final db = sql.sqlite3.open(dbPath);
  try {
    db.execute('BEGIN IMMEDIATE');
    try {
      final rows = db.select('SELECT key, path FROM cache_entry');
      var rewritten = 0;
      final cacheHasRoot = db
          .select('PRAGMA table_info(cache_entry)')
          .any((row) => row['name'] == 'storage_root_id');
      final statement = db.prepare(
        cacheHasRoot
            ? 'UPDATE cache_entry SET path = ?, storage_root_id = ? '
                'WHERE key = ?'
            : 'UPDATE cache_entry SET path = ? WHERE key = ?',
      );
      try {
        for (final row in rows) {
          final key = row['key']! as String;
          final path = row['path']! as String;
          if (!(path == oldPrefix ||
              path.startsWith('$oldPrefix$separator'))) {
            continue;
          }
          final updated = newPrefix + path.substring(oldPrefix.length);
          statement.execute(
            cacheHasRoot
                ? <Object?>[updated, newPrefix, key]
                : <Object?>[updated, key],
          );
          rewritten++;
        }
      } finally {
        statement.dispose();
      }
      final artifactTable = db.select(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'artifact_object'",
      );
      if (artifactTable.isNotEmpty) {
        final rows = db.select(
          'SELECT artifact_id, path FROM artifact_object',
        );
        for (final row in rows) {
          final path = row['path']! as String;
          if (path == oldPrefix || path.startsWith('$oldPrefix$separator')) {
            final updated = newPrefix + path.substring(oldPrefix.length);
            db.execute(
              'UPDATE artifact_object SET path = ?, storage_root_id = ? '
              'WHERE artifact_id = ?',
              <Object?>[updated, newPrefix, row['artifact_id']! as String],
            );
          }
        }
      }
      final replicaTable = db.select(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'artifact_replica'",
      );
      if (replicaTable.isNotEmpty) {
        final rows = db.select(
          'SELECT replica_id, access_locator FROM artifact_replica',
        );
        for (final row in rows) {
          final path = row['access_locator']! as String;
          if (path == oldPrefix || path.startsWith('$oldPrefix$separator')) {
            final updated = newPrefix + path.substring(oldPrefix.length);
            db.execute(
              'UPDATE artifact_replica SET access_locator = ?, storage_root_id = ? '
              'WHERE replica_id = ?',
              <Object?>[updated, newPrefix, row['replica_id']! as String],
            );
          }
        }
      }
      final migrationTable = db.select(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'artifact_replica_migration'",
      );
      if (migrationTable.isNotEmpty) {
        final rows = db.select(
          'SELECT replica_id, source_access_locator, source_storage_root_id, '
          'destination_access_locator, destination_storage_root_id, '
          'temporary_access_locator FROM artifact_replica_migration',
        );
        for (final row in rows) {
          var source = row['source_access_locator']! as String;
          var sourceRoot = (row['source_storage_root_id'] as String?) ?? 'default';
          var destination = row['destination_access_locator']! as String;
          var destinationRoot =
              (row['destination_storage_root_id'] as String?) ?? 'default';
          var temporary = row['temporary_access_locator']! as String;
          var changed = false;
          if (source == oldPrefix || source.startsWith('$oldPrefix$separator')) {
            source = newPrefix + source.substring(oldPrefix.length);
            sourceRoot = newPrefix;
            changed = true;
          }
          if (destination == oldPrefix ||
              destination.startsWith('$oldPrefix$separator')) {
            destination = newPrefix + destination.substring(oldPrefix.length);
            destinationRoot = newPrefix;
            changed = true;
          }
          if (temporary == oldPrefix ||
              temporary.startsWith('$oldPrefix$separator')) {
            temporary = newPrefix + temporary.substring(oldPrefix.length);
            changed = true;
          }
          if (changed) {
            db.execute(
              'UPDATE artifact_replica_migration SET '
              'source_access_locator = ?, source_storage_root_id = ?, '
              'destination_access_locator = ?, destination_storage_root_id = ?, '
              'temporary_access_locator = ? WHERE replica_id = ?',
              <Object?>[
                source,
                sourceRoot,
                destination,
                destinationRoot,
                temporary,
                row['replica_id']! as String,
              ],
            );
          }
        }
      }
      final rootTable = db.select(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'storage_root'",
      );
      final accessTable = db.select(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'storage_access_locator'",
      );
      if (rootTable.isNotEmpty && accessTable.isNotEmpty) {
        final nowUs = DateTime.now().toUtc().microsecondsSinceEpoch;
        db.execute(
          'INSERT INTO storage_root (root_id, created_us, touched_us) '
          'VALUES (?, ?, ?) ON CONFLICT(root_id) DO UPDATE SET touched_us = ?',
          <Object?>[newPrefix, nowUs, nowUs, nowUs],
        );
        db.execute(
          'INSERT INTO storage_access_locator '
          '(kind, locator, root_id, health, verified_us, touched_us) '
          "VALUES ('direct', ?, ?, 'unknown', NULL, ?) "
          'ON CONFLICT(kind, locator) DO UPDATE SET '
          'root_id = excluded.root_id, touched_us = excluded.touched_us',
          <Object?>[newPrefix, newPrefix, nowUs],
        );
      }
      // The placement table is scoped to this SQLite store as well. Keeping
      // its root identity in sync prevents a queue opened after migration
      // from treating a moved placement as belonging to the old authority.
      final placementTable = db.select(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'download_placement'",
      );
      if (placementTable.isNotEmpty) {
        db.execute(
          'UPDATE download_placement SET storage_root_id = ? '
          'WHERE storage_root_id = ? OR storage_root_id = ?',
          <Object?>[newPrefix, oldPrefix, 'default'],
        );
      }
      db.execute('COMMIT');
      return rewritten;
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  } finally {
    db.close();
  }
}

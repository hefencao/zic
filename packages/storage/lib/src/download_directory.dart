import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sql;

/// Default chapter-download store directory under the application storage
/// root. The store layout itself is [CacheLayout] (`cache.sqlite`, `partial/`,
/// `final/`) owned by `PersistentDownloadArtifactStore`.
String defaultChapterDownloadDirectory(String storageRoot) {
  final separator = Platform.pathSeparator;
  return '${_stripTrailingSeparator(storageRoot)}${separator}offline_chapters';
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
  final probe = File(
    '${_stripTrailingSeparator(directory)}'
    '${Platform.pathSeparator}.zic-write-probe',
  );
  await probe.writeAsBytes(const <int>[0], flush: true);
  await probe.delete();
}

/// Returns whether [directory] already holds chapter-download store content.
bool chapterDownloadStoreHasContent(String directory) {
  final root = Directory(directory);
  if (!root.existsSync()) return false;
  if (File('${root.path}${Platform.pathSeparator}cache.sqlite').existsSync()) {
    return true;
  }
  for (final name in const <String>['partial', 'final']) {
    final dir = Directory('${root.path}${Platform.pathSeparator}$name');
    if (dir.existsSync() && dir.listSync(followLinks: false).isNotEmpty) {
      return true;
    }
  }
  return false;
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

/// Moves one chapter-download store (SQLite index plus partial/final artifact
/// bytes) from [from] to [to], rewriting every indexed record path to the new
/// location.
///
/// Index and artifacts always travel together: callers must never point the
/// download configuration at a new directory while leaving either side behind.
/// The operation is idempotent so a crashed earlier attempt can be completed
/// by running it again.
///
/// Throws [ArgumentError] when the source has no movable content, both paths
/// are equal, or one path contains the other; moving between nested
/// directories would make the source and target stores ambiguous.
Future<ChapterDownloadStoreMoveReport> moveChapterDownloadStore({
  required String from,
  required String to,
}) async {
  final source = _stripTrailingSeparator(from);
  final target = _stripTrailingSeparator(to);
  if (!_containsStore(source)) {
    throw ArgumentError.value(
      from,
      'from',
      'chapter-download store has no movable content',
    );
  }
  if (isSameOrNestedDirectoryPath(source, target)) {
    throw ArgumentError.value(
      to,
      'to',
      'must not be the download directory itself or inside it',
    );
  }
  final sourceRoot = Directory(source);
  final targetRoot = Directory(target);
  await targetRoot.create(recursive: true);

  var movedFiles = 0;
  Future<void> moveFile(File file, File destination) async {
    if (!file.existsSync()) return;
    await destination.parent.create(recursive: true);
    try {
      await file.rename(destination.path);
    } on FileSystemException {
      // Cross-volume moves cannot rename; fall back to a staged copy so a
      // crash mid-copy never leaves a truncated file at the destination:
      // bytes land at `*.zic-move-tmp` first and are renamed into place only
      // after the copy completed. A leftover tmp file is harmless and is
      // overwritten by the next idempotent attempt.
      final staged = File('${destination.path}.zic-move-tmp');
      await file.copy(staged.path);
      await staged.rename(destination.path);
      await file.delete();
    }
    movedFiles++;
  }

  final separator = Platform.pathSeparator;
  for (final suffix in const <String>['', '-wal', '-shm', '-journal']) {
    await moveFile(
      File('${sourceRoot.path}${separator}cache.sqlite$suffix'),
      File('${targetRoot.path}${separator}cache.sqlite$suffix'),
    );
  }
  for (final name in const <String>['partial', 'final']) {
    final sourceDir = Directory('${sourceRoot.path}$separator$name');
    if (!sourceDir.existsSync()) continue;
    final targetDir = Directory('${targetRoot.path}$separator$name');
    await targetDir.create(recursive: true);
    await for (final entity in sourceDir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.path.substring(sourceDir.path.length + 1);
      await moveFile(entity, File('${targetDir.path}$separator$name'));
    }
  }

  final rewrittenRecords = _rewriteIndexPaths(
    dbPath: '${targetRoot.path}${separator}cache.sqlite',
    oldPrefix: source,
    newPrefix: target,
  );
  return ChapterDownloadStoreMoveReport(
    movedFileCount: movedFiles,
    rewrittenRecordCount: rewrittenRecords,
  );
}

bool _containsStore(String directory) =>
    chapterDownloadStoreHasContent(directory);

/// Compares two directory paths after removing trailing separators.
bool isSameDirectoryPath(String a, String b) =>
    _stripTrailingSeparator(a) == _stripTrailingSeparator(b);

/// Returns whether the two paths are equal or one contains the other.
///
/// Moving a download store between nested directories would make the source
/// and target stores ambiguous, so callers refuse this relation up front.
bool isSameOrNestedDirectoryPath(String a, String b) {
  final separator = Platform.pathSeparator;
  final left = _withTrailingSeparator(_stripTrailingSeparator(a), separator);
  final right = _withTrailingSeparator(_stripTrailingSeparator(b), separator);
  return left == right || right.startsWith(left) || left.startsWith(right);
}

String _withTrailingSeparator(String path, String separator) =>
    path.endsWith(separator) ? path : '$path$separator';

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
      final statement = db.prepare(
        'UPDATE cache_entry SET path = ? WHERE key = ?',
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
          statement.execute(<Object?>[updated, key]);
          rewritten++;
        }
      } finally {
        statement.dispose();
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

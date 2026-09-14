import 'dart:io';

import 'package:domain/domain.dart';

import 'cache_index.dart';
import 'cache_layout.dart';

final class ScanReport {
  const ScanReport({
    required this.recovered,
    required this.removedRecords,
    required this.deletedOrphans,
    required this.protected,
    required this.invalidMeta,
  });

  final int recovered;
  final int removedRecords;
  final int deletedOrphans;
  final int protected;
  final int invalidMeta;
}

final class CacheScanner {
  CacheScanner({
    required this.layout,
    required this.index,
    Set<String> activePaths = const <String>{},
  }) : activePaths = activePaths.map(_absolute).toSet();

  final CacheLayout layout;
  final CacheIndex index;
  final Set<String> activePaths;

  Future<ScanReport> scan() async {
    _rejectPathLinks(layout.partialDir);
    _rejectPathLinks(layout.finalDir);
    for (final path in <String>[layout.partialDir, layout.finalDir]) {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'cache data directory must not be a symlink',
        );
      }
      await Directory(path).create(recursive: true);
    }

    var removedRecords = 0;
    var deletedOrphans = 0;
    var protected = 0;
    final managedData = <String>{};
    final managedMetadata = <String>{};

    // Sidecars are transfer/resume metadata only. They may be completed for a
    // path that already has durable authority, but they never create that
    // authority and never decide whether authoritative bytes survive.
    for (final dir in <Directory>[
      Directory(layout.partialDir),
      Directory(layout.finalDir),
    ]) {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.meta.tmp')) continue;
        final dataPath = entity.path.substring(
          0,
          entity.path.length - '.meta.tmp'.length,
        );
        final absoluteData = _absolute(dataPath);
        final owned = activePaths.contains(absoluteData) ||
            await _isDurableAuthority(dataPath);
        if (!owned) {
          await entity.delete();
          deletedOrphans++;
          continue;
        }
        final finalMeta = File('$dataPath.meta');
        if (await _isRegularFile(dataPath) &&
            !await _isRegularFile(finalMeta.path)) {
          await entity.rename(finalMeta.path);
          managedMetadata.add(_absolute(finalMeta.path));
        } else if (await _isRegularFile(finalMeta.path)) {
          await entity.delete();
          managedMetadata.add(_absolute(finalMeta.path));
        }
        protected++;
      }
    }

    // A durable DB row/replica owns the body. Missing, malformed or historical
    // sidecars cannot retire that body. Conversely, an unindexed sidecar is not
    // allowed to reconstruct a durable partial/READY fact after a crash.
    for (final dir in <Directory>[
      Directory(layout.partialDir),
      Directory(layout.finalDir),
    ]) {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.meta')) continue;
        final absoluteMeta = _absolute(entity.path);
        if (managedMetadata.contains(absoluteMeta)) continue;
        final dataPath = entity.path.substring(0, entity.path.length - 5);
        final absoluteData = _absolute(dataPath);
        final owned = activePaths.contains(absoluteData) ||
            await _isDurableAuthority(dataPath);
        if (owned) {
          managedMetadata.add(absoluteMeta);
          if (await _isRegularFile(dataPath)) managedData.add(absoluteData);
          protected++;
          continue;
        }
        await entity.delete();
        deletedOrphans++;
      }
    }

    // Byte cleanup is authority-driven. An indexed partial, artifact replica,
    // or live migration path is preserved without consulting a sidecar. A file
    // with no durable/live owner is uncommitted crash garbage and may be
    // deleted; its sidecar cannot promote it back into the DB.
    for (final dir in <Directory>[
      Directory(layout.partialDir),
      Directory(layout.finalDir),
    ]) {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File &&
            (entity.path.endsWith('.meta') ||
                entity.path.endsWith('.meta.tmp'))) {
          continue;
        }
        final absolute = _absolute(entity.path);
        if (managedData.contains(absolute)) continue;
        final owned = activePaths.contains(absolute) ||
            await _isDurableAuthority(entity.path);
        if (owned) {
          protected++;
          managedData.add(absolute);
          continue;
        }
        if (entity is File || entity is Link) {
          await entity.delete();
          deletedOrphans++;
        }
      }
    }

    // READY cache_entry.path is only a compatibility mirror; schema-8
    // artifact_replica is the sealed locator authority and its structural
    // failures are retired by the normal replica read path. Mutable exact
    // partial rows still directly own their path, so a missing body can be
    // removed here without conflating the two models.
    for (final rec in await index.list(state: CacheState.partial)) {
      if (!_belongsToThisCacheRoot(rec.path, layout.root)) continue;
      if (await _isRegularFile(rec.path)) continue;
      if (activePaths.contains(_absolute(rec.path))) {
        protected++;
        continue;
      }
      await index.remove(rec.key);
      removedRecords++;
    }

    return ScanReport(
      recovered: 0,
      removedRecords: removedRecords,
      deletedOrphans: deletedOrphans,
      protected: protected,
      invalidMeta: 0,
    );
  }

  Future<bool> _isDurableAuthority(String path) async {
    if (index is! StorageAccessAuthorityQuery) return false;
    return (index as StorageAccessAuthorityQuery)
        .isStorageAccessLocatorAuthoritative(path);
  }
}

String _absolute(String path) => File(path).absolute.path;

bool _belongsToThisCacheRoot(String path, String root) {
  if (path.startsWith('saf:')) return false;
  final uri = Uri.tryParse(path);
  final isWindowsDrivePath = path.length >= 3 &&
      path.codeUnitAt(1) == 0x3a &&
      (path.codeUnitAt(2) == 0x5c || path.codeUnitAt(2) == 0x2f);
  if (uri != null && uri.scheme.isNotEmpty && !isWindowsDrivePath) {
    return false;
  }
  final absolutePath = _absolute(path);
  final absoluteRoot = _absolute(root);
  final separator = Platform.pathSeparator;
  final prefix = absoluteRoot.endsWith(separator)
      ? absoluteRoot
      : '$absoluteRoot$separator';
  return absolutePath == absoluteRoot || absolutePath.startsWith(prefix);
}

Future<bool> _isRegularFile(String path) async =>
    await FileSystemEntity.type(path, followLinks: false) ==
    FileSystemEntityType.file;

void _rejectPathLinks(String path) {
  if (FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.link) {
    throw const Failure(
      code: ErrorCode.artifactCorruption,
      message: 'cache path must not contain a symbolic link',
    );
  }
  final parent = Directory(path).parent.path;
  if (FileSystemEntity.typeSync(parent, followLinks: false) ==
      FileSystemEntityType.link) {
    throw const Failure(
      code: ErrorCode.artifactCorruption,
      message: 'cache path must not contain a symbolic link',
    );
  }
}

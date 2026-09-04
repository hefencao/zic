import 'dart:convert';
import 'dart:io';

import 'package:domain/domain.dart';

import 'cache_index.dart';
import 'cache_layout.dart';
import 'crc32.dart';

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

    var recovered = 0;
    var removedRecords = 0;
    var deletedOrphans = 0;
    var protected = 0;
    var invalidMeta = 0;
    final managedData = <String>{};
    final managedMetadata = <String>{};

    for (final dir in <Directory>[
      Directory(layout.partialDir),
      Directory(layout.finalDir),
    ]) {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.meta.tmp')) {
          final dataPath = entity.path.substring(
            0,
            entity.path.length - '.meta.tmp'.length,
          );
          final finalMeta = File('$dataPath.meta');
          if (await _isRegularFile(dataPath) &&
              !await _isRegularFile(finalMeta.path)) {
            await entity.rename(finalMeta.path);
          } else if (!activePaths.contains(_absolute(dataPath))) {
            await entity.delete();
          }
        }
      }
    }

    // Promotion renames the sealed partial before it installs the ready
    // sidecar. If the process dies in that window, the final body is an
    // orphan from the final directory's perspective while its authoritative
    // sealed metadata still lives beside the old partial path. Recover that
    // boundary before the ordinary partial scan can delete the metadata.
    await for (final entity in Directory(layout.finalDir).list(
      followLinks: false,
    )) {
      if (entity is! File ||
          !entity.path.endsWith('.bin') ||
          await _isRegularFile('${entity.path}.meta')) {
        continue;
      }
      final recovery = await _recoverRenamedFinal(entity);
      if (recovery == null) continue;
      final absoluteFinal = _absolute(entity.path);
      if (recovery.invalid) {
        if (activePaths.contains(absoluteFinal)) {
          protected++;
          managedData.add(absoluteFinal);
        } else {
          await entity.delete();
          for (final file in recovery.sourceMetadata) {
            if (await _isRegularFile(file.path)) await file.delete();
          }
          invalidMeta++;
        }
        continue;
      }
      final stat = await entity.stat();
      final checksum = await _checksum(entity);
      await _writeReadyMetadata(
        File('${entity.path}.meta'),
        recovery.metadata,
        stat.size,
        checksum,
      );
      for (final file in recovery.sourceMetadata) {
        if (await _isRegularFile(file.path)) await file.delete();
      }
      final previous = await _existingBinding(recovery.id!, entity.path);
      await index.put(
        CacheRec(
          id: recovery.id!,
          state: CacheState.ready,
          path: entity.path,
          bytes: stat.size,
          checksum: checksum,
          createdUs: _intOr(
            recovery.metadata['createdUs'],
            stat.changed.toUtc().microsecondsSinceEpoch,
          ),
          touchedUs: _intOr(
            recovery.metadata['touchedUs'],
            stat.modified.toUtc().microsecondsSinceEpoch,
          ),
          pinned: previous?.pinned ?? false,
          checksumAlgorithm: previous?.checksumAlgorithm ?? 'crc32',
          artifactId: previous?.artifactId ?? '',
          storageRootId: previous?.storageRootId ?? 'default',
        ),
      );
      managedData.add(absoluteFinal);
      managedMetadata.add(_absolute('${entity.path}.meta'));
      recovered++;
    }

    for (final dir in <Directory>[
      Directory(layout.partialDir),
      Directory(layout.finalDir),
    ]) {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.meta')) {
          continue;
        }
        if (managedMetadata.contains(_absolute(entity.path))) {
          continue;
        }
        final dataPath = entity.path.substring(0, entity.path.length - 5);
        final data = File(dataPath);
        if (!await _isRegularFile(data.path)) {
          if (activePaths.contains(_absolute(dataPath))) {
            protected++;
          } else {
            await entity.delete();
            invalidMeta++;
          }
          continue;
        }

        late final DownloadId id;
        late final Map<String, Object?> meta;
        try {
          final raw = jsonDecode(await entity.readAsString());
          if (raw is! Map) {
            throw const FormatException('metadata root must be an object');
          }
          meta = Map<String, Object?>.from(raw);
          final rawId = meta['download'];
          if (rawId is! Map) {
            throw const FormatException('download metadata is missing');
          }
          id = DownloadId.fromJson(Map<String, Object?>.from(rawId));
        } on FormatException {
          if (activePaths.contains(_absolute(dataPath))) {
            protected++;
          } else {
            await entity.delete();
            await data.delete();
            invalidMeta++;
          }
          continue;
        } on TypeError {
          if (activePaths.contains(_absolute(dataPath))) {
            protected++;
          } else {
            await entity.delete();
            await data.delete();
            invalidMeta++;
          }
          continue;
        }

        final stat = await data.stat();
        final checksum = await _checksum(data);
        final state = _absolute(dataPath).startsWith(_absolute(layout.finalDir))
            ? CacheState.ready
            : CacheState.partial;
        if (state == CacheState.ready &&
            _readyMetadataDisagrees(meta, stat.size, checksum)) {
          final absoluteDataPath = _absolute(dataPath);
          if (activePaths.contains(absoluteDataPath)) {
            // An active owner may still be completing the promotion boundary;
            // do not delete bytes out from under it or replace its index row
            // during startup recovery.
            protected++;
            managedData.add(absoluteDataPath);
          } else {
            await entity.delete();
            await data.delete();
            final existing = await index.get(id.key);
            if (existing != null && _absolute(existing.path) == absoluteDataPath) {
              await index.remove(existing.key);
            }
            invalidMeta++;
          }
          continue;
        }
        final createdUs = _intOr(
          meta['createdUs'],
          stat.changed.toUtc().microsecondsSinceEpoch,
        );
        final touchedUs = _intOr(
          meta['touchedUs'],
          stat.modified.toUtc().microsecondsSinceEpoch,
        );
        final previous = await _existingBinding(id, dataPath);
        await index.put(
          CacheRec(
            id: id,
            state: state,
            path: dataPath,
            bytes: stat.size,
            checksum: checksum,
            createdUs: createdUs,
            touchedUs: touchedUs,
            pinned: previous?.pinned ?? false,
            checksumAlgorithm: previous?.checksumAlgorithm ?? 'crc32',
            artifactId: previous?.artifactId ?? '',
            storageRootId: previous?.storageRootId ?? 'default',
          ),
        );
        managedData.add(_absolute(dataPath));
        recovered++;
      }
    }

    for (final dir in <Directory>[
      Directory(layout.partialDir),
      Directory(layout.finalDir),
    ]) {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is Link) {
          final absolute = _absolute(entity.path);
          if (activePaths.contains(absolute)) {
            protected++;
          } else {
            await entity.delete();
            deletedOrphans++;
          }
          continue;
        }
        if (entity is! File ||
            entity.path.endsWith('.meta') ||
            entity.path.endsWith('.meta.tmp')) {
          continue;
        }
        final absolute = _absolute(entity.path);
        if (managedData.contains(absolute)) {
          continue;
        }
        if (activePaths.contains(absolute)) {
          protected++;
        } else {
          await entity.delete();
          deletedOrphans++;
        }
      }
    }

    for (final rec in await index.list()) {
      if (!_belongsToThisCacheRoot(rec.path, layout.root)) {
        // The shared index may also contain structured POSIX bindings,
        // historical-root records, or SAF record paths. This scanner owns
        // only its local partial/final cache root; removing an external
        // binding because it is not a local File would orphan its bytes.
        continue;
      }
      if (!await _isRegularFile(rec.path)) {
        if (activePaths.contains(_absolute(rec.path))) {
          protected++;
        } else {
          await index.remove(rec.key);
          removedRecords++;
        }
      }
    }

    return ScanReport(
      recovered: recovered,
      removedRecords: removedRecords,
      deletedOrphans: deletedOrphans,
      protected: protected,
      invalidMeta: invalidMeta,
    );
  }

  Future<CacheRec?> _existingBinding(DownloadId id, String path) async {
    final existing = await index.get(id.key);
    if (existing == null || _absolute(existing.path) != _absolute(path)) {
      return null;
    }
    return existing;
  }

  Future<_RenamedFinalRecovery?> _recoverRenamedFinal(File finalFile) async {
    final name = finalFile.uri.pathSegments.last;
    if (!name.endsWith('.bin')) return null;
    final token = name.substring(0, name.length - '.bin'.length);
    final separator = Platform.pathSeparator;
    final sourceMetadata = <File>[
      File('${layout.partialDir}$separator$token.part.meta'),
      File('${layout.partialDir}$separator$token.part.meta.tmp'),
    ].where(
      (file) =>
          FileSystemEntity.typeSync(
            file.path,
            followLinks: false,
          ) ==
          FileSystemEntityType.file,
    ).toList(growable: false);
    if (sourceMetadata.isEmpty) return null;

    final metadataFile = sourceMetadata.first;
    try {
      final raw = jsonDecode(await metadataFile.readAsString());
      if (raw is! Map) {
        throw const FormatException('metadata root must be an object');
      }
      final metadata = Map<String, Object?>.from(raw);
      final rawId = metadata['download'];
      if (rawId is! Map) {
        throw const FormatException('download metadata is missing');
      }
      final id = DownloadId.fromJson(Map<String, Object?>.from(rawId));
      final stat = await finalFile.stat();
      final checksum = await _checksum(finalFile);
      return _RenamedFinalRecovery(
        id: id,
        metadata: metadata,
        sourceMetadata: sourceMetadata,
        invalid: _readyMetadataDisagrees(metadata, stat.size, checksum),
      );
    } on FormatException {
      return _RenamedFinalRecovery(
        sourceMetadata: sourceMetadata,
        invalid: true,
      );
    } on TypeError {
      return _RenamedFinalRecovery(
        sourceMetadata: sourceMetadata,
        invalid: true,
      );
    } on Failure catch (error) {
      if (error.code != ErrorCode.artifactCorruption) rethrow;
      return _RenamedFinalRecovery(
        sourceMetadata: sourceMetadata,
        invalid: true,
      );
    }
  }

  Future<void> _writeReadyMetadata(
    File target,
    Map<String, Object?> source,
    int bytes,
    String checksum,
  ) async {
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    await target.parent.create(recursive: true);
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(
      jsonEncode(<String, Object?>{
        ...source,
        'artifactState': 'ready',
        'path': target.path.substring(0, target.path.length - 5),
        'bytes': bytes,
        'checksum': checksum,
        'touchedUs': now,
        'createdUs': source['createdUs'] is int ? source['createdUs'] : now,
      }),
      flush: true,
    );
    try {
      await temp.rename(target.path);
    } on FileSystemException {
      if (await _isRegularFile(target.path)) await target.delete();
      await temp.rename(target.path);
    }
  }

  Future<String> _checksum(File file) async {
    final crc = Crc32();
    await for (final chunk in file.openRead()) {
      crc.add(chunk);
    }
    return crc.hex;
  }
}

final class _RenamedFinalRecovery {
  const _RenamedFinalRecovery({
    this.id,
    this.metadata = const <String, Object?>{},
    this.sourceMetadata = const <File>[],
    required this.invalid,
  });

  final DownloadId? id;
  final Map<String, Object?> metadata;
  final List<File> sourceMetadata;
  final bool invalid;
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

int _intOr(Object? value, int fallback) => value is int ? value : fallback;

bool _readyMetadataDisagrees(
  Map<String, Object?> metadata,
  int dataLength,
  String checksum,
) {
  final declaredBytes = metadata['bytes'];
  if (declaredBytes is int && declaredBytes != dataLength) {
    return true;
  }
  final declaredChecksum = metadata['checksum'];
  if (declaredChecksum == null) {
    // Older interrupted-promotion metadata may not have persisted a checksum;
    // the scanner's freshly computed CRC becomes the new physical proof.
    return false;
  }
  if (declaredChecksum is! String ||
      !RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(declaredChecksum)) {
    return true;
  }
  return declaredChecksum.toLowerCase() != checksum.toLowerCase();
}

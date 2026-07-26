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
    await Directory(layout.partialDir).create(recursive: true);
    await Directory(layout.finalDir).create(recursive: true);

    var recovered = 0;
    var removedRecords = 0;
    var deletedOrphans = 0;
    var protected = 0;
    var invalidMeta = 0;
    final managedData = <String>{};

    for (final dir in <Directory>[
      Directory(layout.partialDir),
      Directory(layout.finalDir),
    ]) {
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.meta.tmp')) {
          final dataPath = entity.path.substring(
            0,
            entity.path.length - '.meta.tmp'.length,
          );
          final finalMeta = File('$dataPath.meta');
          if (await File(dataPath).exists() && !await finalMeta.exists()) {
            await entity.rename(finalMeta.path);
          } else if (!activePaths.contains(_absolute(dataPath))) {
            await entity.delete();
          }
        }
      }
    }

    for (final dir in <Directory>[
      Directory(layout.partialDir),
      Directory(layout.finalDir),
    ]) {
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.meta')) {
          continue;
        }
        final dataPath = entity.path.substring(0, entity.path.length - 5);
        final data = File(dataPath);
        if (!await data.exists()) {
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
        final createdUs = _intOr(
          meta['createdUs'],
          stat.changed.toUtc().microsecondsSinceEpoch,
        );
        final touchedUs = _intOr(
          meta['touchedUs'],
          stat.modified.toUtc().microsecondsSinceEpoch,
        );
        await index.put(
          CacheRec(
            id: id,
            state: state,
            path: dataPath,
            bytes: stat.size,
            checksum: checksum,
            createdUs: createdUs,
            touchedUs: touchedUs,
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
      await for (final entity in dir.list()) {
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
      if (!await File(rec.path).exists()) {
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

  Future<String> _checksum(File file) async {
    final crc = Crc32();
    await for (final chunk in file.openRead()) {
      crc.add(chunk);
    }
    return crc.hex;
  }
}

String _absolute(String path) => File(path).absolute.path;

int _intOr(Object? value, int fallback) => value is int ? value : fallback;

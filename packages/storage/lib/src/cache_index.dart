import 'dart:convert';

import 'package:domain/domain.dart';
import 'download_placement.dart';

enum CacheState { partial, ready }

String defaultArtifactIdForPath(String path) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode('artifact:$path')) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

final class CacheRec {
  const CacheRec({
    required this.id,
    required this.state,
    required this.path,
    required this.bytes,
    required this.checksum,
    required this.createdUs,
    required this.touchedUs,
    this.pinned = false,
    this.checksumAlgorithm = 'crc32',
    this.artifactId = '',
    this.storageRootId = 'default',
  });

  final DownloadId id;
  final CacheState state;
  final String path;
  final int bytes;
  final String checksum;
  final int createdUs;
  final int touchedUs;

  /// Explicitly downloaded content is protected from capacity trims and
  /// cache clears; only an explicit per-chapter delete may remove it.
  final bool pinned;

  /// The checksum namespace is persisted separately from the digest value.
  /// Historical rows default to CRC-32, which is the artifact proof produced
  /// by the storage layer.
  final String checksumAlgorithm;

  /// Stable physical-object identity. A logical page binding may move between
  /// export paths without changing this value; equivalent bindings may share
  /// it when they intentionally reference the same immutable object.
  final String artifactId;

  /// Physical storage-root identity captured when the binding was committed.
  /// Legacy rows use `default` and remain readable until an explicit root
  /// reconciliation can establish a stronger identity.
  final String storageRootId;

  String get key => id.key;

  /// Returns the physical-object identity used by persistent indexes when a
  /// caller did not provide an explicit identity. SQLite materializes this
  /// value on write; exposing the same normalization keeps stale-write
  /// comparisons correct across [CacheIndex] implementations.
  String get effectiveArtifactId =>
      artifactId.isEmpty ? defaultArtifactIdForPath(path) : artifactId;

  CacheRec copyWith({
    CacheState? state,
    String? path,
    int? bytes,
    String? checksum,
    int? createdUs,
    int? touchedUs,
    bool? pinned,
    String? checksumAlgorithm,
    String? artifactId,
    String? storageRootId,
  }) {
    return CacheRec(
      id: id,
      state: state ?? this.state,
      path: path ?? this.path,
      bytes: bytes ?? this.bytes,
      checksum: checksum ?? this.checksum,
      createdUs: createdUs ?? this.createdUs,
      touchedUs: touchedUs ?? this.touchedUs,
      pinned: pinned ?? this.pinned,
      checksumAlgorithm: checksumAlgorithm ?? this.checksumAlgorithm,
      artifactId: artifactId ?? this.artifactId,
      storageRootId: storageRootId ?? this.storageRootId,
    );
  }

  Map<String, Object> toJson() => <String, Object>{
        'download': id.toJson(),
        'state': state.name,
        'path': path,
        'bytes': bytes,
        'checksum': checksum,
        'createdUs': createdUs,
        'touchedUs': touchedUs,
        'pinned': pinned,
        'checksumAlgorithm': checksumAlgorithm,
        'artifactId': artifactId,
        'storageRootId': storageRootId,
      };

  factory CacheRec.fromJson(Map<String, Object?> json) {
    final rawId = json['download'];
    if (rawId is! Map) {
      throw const FormatException('download must be an object');
    }
    return CacheRec(
      id: DownloadId.fromJson(Map<String, Object?>.from(rawId)),
      state: CacheState.values.byName(json['state']! as String),
      path: json['path']! as String,
      bytes: json['bytes']! as int,
      checksum: json['checksum']! as String,
      createdUs: json['createdUs']! as int,
      touchedUs: json['touchedUs']! as int,
      pinned: json['pinned'] == true,
      checksumAlgorithm: (json['checksumAlgorithm'] as String?) ?? 'crc32',
      artifactId: (json['artifactId'] as String?) ?? '',
      storageRootId: (json['storageRootId'] as String?) ?? 'default',
    );
  }
}

/// Optional transactional binding capability. A path may be shared by
/// verified logical identities, but an explicit overwrite must replace the
/// old logical bindings in the same SQLite transaction as the new one.
abstract interface class CacheBindingOperations {
  Future<void> replacePathBindings({
    required CacheRec record,
    required String path,
  });
}

abstract interface class CacheIndex {
  Future<void> open();

  Future<CacheRec?> get(String key);

  Future<List<CacheRec>> list({CacheState? state});

  Future<void> put(CacheRec rec);

  Future<void> remove(String key);

  Future<void> touch(String key, int touchedUs);

  Future<int> totalBytes({CacheState? state});

  Future<DownloadPlacement?> getPlacement({
    required String sourceId,
    required String comicId,
  });

  Future<List<DownloadPlacement>> listPlacements();

  Future<void> putPlacement(DownloadPlacement placement);

  Future<void> removePlacement({
    required String sourceId,
    required String comicId,
  });

  Future<bool> isPathOrArtifactReferenced({
    required String path,
    required String artifactId,
    String? excludingKey,
  });

  Future<void> close();
}

final class MemIndex implements CacheIndex, CacheBindingOperations {
  final Map<String, CacheRec> _records = <String, CacheRec>{};
  final Map<String, DownloadPlacement> _placements =
      <String, DownloadPlacement>{};
  bool _closed = true;

  @override
  Future<void> open() async {
    _closed = false;
  }

  @override
  Future<CacheRec?> get(String key) async {
    _requireOpen();
    return _records[key];
  }

  @override
  Future<List<CacheRec>> list({CacheState? state}) async {
    _requireOpen();
    final records = _records.values
        .where((record) => state == null || record.state == state)
        .toList(growable: false)
      ..sort((a, b) => a.key.compareTo(b.key));
    return records;
  }

  @override
  Future<void> put(CacheRec rec) async {
    _requireOpen();
    _records[rec.key] = rec;
  }

  @override
  Future<void> remove(String key) async {
    _requireOpen();
    _records.remove(key);
  }

  @override
  Future<void> replacePathBindings({
    required CacheRec record,
    required String path,
  }) async {
    _requireOpen();
    _records.removeWhere(
      (key, value) => value.path == path && key != record.key,
    );
    _records[record.key] = record;
  }

  @override
  Future<void> touch(String key, int touchedUs) async {
    _requireOpen();
    final current = _records[key];
    if (current != null) {
      _records[key] = current.copyWith(touchedUs: touchedUs);
    }
  }

  @override
  Future<int> totalBytes({CacheState? state}) async {
    _requireOpen();
    return _records.values
        .where((record) => state == null || record.state == state)
        .fold<int>(0, (total, record) => total + record.bytes);
  }

  @override
  Future<DownloadPlacement?> getPlacement({
    required String sourceId,
    required String comicId,
  }) async {
    _requireOpen();
    return _placements['$sourceId\u0000$comicId'];
  }

  @override
  Future<List<DownloadPlacement>> listPlacements() async {
    _requireOpen();
    return _placements.values.toList(growable: false);
  }

  @override
  Future<void> putPlacement(DownloadPlacement placement) async {
    _requireOpen();
    final existing = _placements[placement.ownerKey];
    if (existing != null) {
      final staleGeneration = placement.generation < existing.generation;
      final conflictingEqualGeneration =
          placement.generation == existing.generation &&
              !_samePlacementBinding(placement, existing);
      if (staleGeneration || conflictingEqualGeneration) {
        throw StateError(
          'stale download placement commit for ${placement.ownerKey}',
        );
      }
    }
    _placements[placement.ownerKey] = placement;
  }

  bool _samePlacementBinding(
    DownloadPlacement first,
    DownloadPlacement second,
  ) =>
      first.sourceId == second.sourceId &&
      first.comicId == second.comicId &&
      first.comicTitle == second.comicTitle &&
      first.mode == second.mode &&
      first.relativeDirectory == second.relativeDirectory &&
      first.storageRootId == second.storageRootId &&
      first.comicFamilyId == second.comicFamilyId &&
      first.observedOwnerKey == second.observedOwnerKey &&
      first.pageOrder == second.pageOrder &&
      first.fingerprint == second.fingerprint;

  @override
  Future<void> removePlacement({
    required String sourceId,
    required String comicId,
  }) async {
    _requireOpen();
    _placements.remove('$sourceId\u0000$comicId');
  }

  @override
  Future<bool> isPathOrArtifactReferenced({
    required String path,
    required String artifactId,
    String? excludingKey,
  }) async {
    _requireOpen();
    final effectiveTargetArtifactId =
        artifactId.isEmpty ? defaultArtifactIdForPath(path) : artifactId;
    return _records.values.any(
      (r) =>
          r.key != excludingKey &&
          (r.path == path ||
              r.effectiveArtifactId == effectiveTargetArtifactId),
    );
  }

  @override
  Future<void> close() async {
    _closed = true;
  }

  void _requireOpen() {
    if (_closed) {
      throw StateError('cache index is closed');
    }
  }
}

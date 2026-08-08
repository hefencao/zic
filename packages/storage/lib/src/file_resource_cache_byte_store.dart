import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:resource_cache/resource_cache.dart';

/// Atomic durable backing for immutable response bytes.
///
/// Transient records are bounded by LRU/TTL. Retained artwork is outside that
/// capacity plane and is removed only by explicit invalidation or clear. The
/// file path remains private to this store; callers always receive owned bytes.
/// This keeps persistence lifetime independent from presentation lifetime.
final class FileResourceCacheByteStore implements ResourceCacheByteStore,
    ResourceCacheByteStoreMaintenance {
  FileResourceCacheByteStore(
    String rootPath, {
    this.transientMaxEntries = 96,
    this.transientMaxBytes = 32 * 1024 * 1024,
    DateTime Function()? now,
  })  : assert(transientMaxEntries > 0),
        assert(transientMaxBytes > 0),
        _root = Directory(rootPath),
        _now = now ?? DateTime.now;

  static const int _formatVersion = 2;
  static const int _legacyFormatVersion = 1;
  static const String _manifestName = 'response-manifest-v1.json';

  final Directory _root;
  final int transientMaxEntries;
  final int transientMaxBytes;
  final DateTime Function() _now;
  final Map<String, _FileResourceRecord> _records =
      <String, _FileResourceRecord>{};
  final Map<String, _FileResourceRecord> _pendingTouches =
      <String, _FileResourceRecord>{};
  Future<void>? _manifestLoad;
  bool _manifestDirty = false;
  bool _closed = false;

  @override
  Future<PersistedResourceBytes?> read(ResourceCacheKey key) async {
    _requireOpen();
    final paths = _paths(key);
    final record = await _validatedRecord(paths, key: key);
    if (record == null) {
      return null;
    }
    try {
      final bytes = await paths.bytes.readAsBytes();
      if (bytes.lengthInBytes != record.byteLength ||
          _contentHash(bytes) != record.contentHash) {
        await _removePaths(paths, key: key);
        return null;
      }
      _pendingTouches[_recordId(key)] = record.copyWith(
        lastAccessedAt: _now(),
      );
      return PersistedResourceBytes(
        bytes: bytes,
        expiresAt: record.expiresAt,
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      await _removePaths(paths, key: key);
      return null;
    }
  }

  @override
  Future<void> write({
    required ResourceCacheKey key,
    required Uint8List bytes,
    required DateTime? expiresAt,
    ResourceCacheRetention retention = ResourceCacheRetention.transient,
  }) async {
    _requireOpen();
    await _ensureManifestLoaded();
    if (retention == ResourceCacheRetention.transient &&
        (expiresAt == null || !expiresAt.isAfter(_now()))) {
      await remove(key);
      return;
    }
    await _root.create(recursive: true);
    final paths = _paths(key);
    final id = _recordId(key);
    _pendingTouches.remove(id);
    await paths.bytes.parent.create(recursive: true);
    final now = _now();
    final record = _FileResourceRecord(
      key: key,
      expiresAt: retention == ResourceCacheRetention.retained ? null : expiresAt,
      retention: retention,
      lastAccessedAt: now,
      byteLength: bytes.lengthInBytes,
      contentHash: _contentHash(bytes),
    );
    final bytesTemporary = File('${paths.bytes.path}.tmp');
    final metadataTemporary = File('${paths.metadata.path}.tmp');
    await bytesTemporary.writeAsBytes(bytes, flush: true);
    await metadataTemporary.writeAsString(
      jsonEncode(record.toJson()),
      flush: true,
    );
    await _replace(bytesTemporary, paths.bytes);
    await _replace(metadataTemporary, paths.metadata);
    _records[id] = record;
    _manifestDirty = true;
    await _trim();
    await _flushManifest();
  }

  @override
  Future<void> retain(ResourceCacheKey key) async {
    _requireOpen();
    await _ensureManifestLoaded();
    final id = _recordId(key);
    final current = _pendingTouches[id] ?? _records[id];
    if (current == null || current.key != key) {
      return;
    }
    final currentExpiry = current.expiresAt;
    if (current.retention == ResourceCacheRetention.transient &&
        currentExpiry != null &&
        !currentExpiry.isAfter(_now())) {
      await _removePaths(_paths(key), key: key);
      await _flushManifest();
      return;
    }
    if (current.retention == ResourceCacheRetention.retained) {
      return;
    }
    _pendingTouches.remove(id);
    final retained = current.copyWith(
      retention: ResourceCacheRetention.retained,
      clearExpiresAt: true,
      lastAccessedAt: _now(),
    );
    _records[id] = retained;
    _manifestDirty = true;
    // Retention is lifetime-critical metadata. Keep the per-entry recovery
    // journal in sync so a crash between manifest generations cannot demote a
    // retained library/history cover back into the transient eviction plane.
    final paths = _paths(key);
    await paths.metadata.parent.create(recursive: true);
    final temporary = File('${paths.metadata.path}.tmp');
    await temporary.writeAsString(jsonEncode(retained.toJson()), flush: true);
    await _replace(temporary, paths.metadata);
    await _flushManifest();
  }

  @override
  Future<void> remove(ResourceCacheKey key) async {
    _requireOpen();
    await _ensureManifestLoaded();
    await _removePaths(_paths(key), key: key);
    await _flushManifest();
  }

  @override
  Future<void> removeWhere(
    bool Function(ResourceCacheKey key) predicate,
  ) async {
    _requireOpen();
    await _ensureManifestLoaded();
    final removed = _records.values
        .where((record) => predicate(record.key))
        .toList(growable: false);
    for (final record in removed) {
      await _removePaths(_paths(record.key), key: record.key);
    }
    await _flushManifest();
  }

  @override
  Future<ResourceCacheByteStoreUsage> inspect() async {
    _requireOpen();
    final inventory = await _inventory();
    var retainedBytes = 0;
    var retainedEntries = 0;
    for (final candidate in inventory.records) {
      if (candidate.record.retention == ResourceCacheRetention.retained) {
        retainedBytes += candidate.record.byteLength;
        retainedEntries++;
      }
    }
    return ResourceCacheByteStoreUsage(
      bytes: inventory.totalBytes,
      entries: inventory.records.length,
      retainedBytes: retainedBytes,
      retainedEntries: retainedEntries,
    );
  }

  @override
  Future<ResourceCacheByteStoreTrimReport> trimTo({
    required int targetBytes,
  }) async {
    _requireOpen();
    if (targetBytes < 0) {
      throw ArgumentError.value(targetBytes, 'targetBytes');
    }
    final inventory = await _inventory();
    final transient = inventory.records
        .where(
          (candidate) =>
              candidate.record.retention == ResourceCacheRetention.transient,
        )
        .toList(growable: false);
    final beforeBytes = transient.fold<int>(
      0,
      (sum, candidate) => sum + candidate.record.byteLength,
    );
    var remainingBytes = beforeBytes;
    var evictedEntries = 0;
    for (final candidate in transient) {
      if (remainingBytes <= targetBytes) {
        break;
      }
      await _removePaths(candidate.paths, key: candidate.record.key);
      remainingBytes -= candidate.record.byteLength;
      evictedEntries++;
    }
    await _flushManifest();
    return ResourceCacheByteStoreTrimReport(
      beforeBytes: beforeBytes,
      releasedBytes: beforeBytes - remainingBytes,
      remainingBytes: remainingBytes,
      evictedEntries: evictedEntries,
    );
  }

  @override
  Future<void> clear() async {
    _requireOpen();
    if (await _root.exists()) {
      await _root.delete(recursive: true);
    }
    _records.clear();
    _pendingTouches.clear();
    _manifestDirty = false;
    _manifestLoad = Future<void>.value();
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    if (_manifestLoad != null) {
      await _ensureManifestLoaded();
      _applyPendingTouches();
      await _flushManifest();
    }
    _closed = true;
  }

  Future<void> _trim() async {
    final inventory = await _inventory();
    final transient = inventory.records
        .where(
          (candidate) =>
              candidate.record.retention == ResourceCacheRetention.transient,
        )
        .toList(growable: false);
    var entries = transient.length;
    var totalBytes = transient.fold<int>(
      0,
      (sum, candidate) => sum + candidate.record.byteLength,
    );
    for (final candidate in transient) {
      if (entries <= transientMaxEntries && totalBytes <= transientMaxBytes) {
        break;
      }
      await _removePaths(candidate.paths, key: candidate.record.key);
      entries--;
      totalBytes -= candidate.record.byteLength;
    }
  }

  Future<_FileResourceInventory> _inventory() async {
    await _ensureManifestLoaded();
    if (!await _root.exists()) {
      return const _FileResourceInventory(
        records: <_FileResourceCandidate>[],
        totalBytes: 0,
      );
    }
    final now = _now();
    final records = <_FileResourceCandidate>[];
    var totalBytes = 0;
    final snapshot = _records.values.toList(growable: false);
    for (final stored in snapshot) {
      final id = _recordId(stored.key);
      final record = _pendingTouches[id] ?? stored;
      final paths = _paths(record.key);
      final expiresAt = record.expiresAt;
      if (expiresAt != null && !expiresAt.isAfter(now)) {
        await _removePaths(paths, key: record.key);
        continue;
      }
      final stat = await paths.bytes.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size != record.byteLength) {
        await _removePaths(paths, key: record.key);
        continue;
      }
      records.add(_FileResourceCandidate(paths: paths, record: record));
      totalBytes += stat.size;
    }
    records.sort(
      (left, right) => left.record.lastAccessedAt.compareTo(
        right.record.lastAccessedAt,
      ),
    );
    return _FileResourceInventory(
      records: List<_FileResourceCandidate>.unmodifiable(records),
      totalBytes: totalBytes,
    );
  }

  Future<_FileResourceRecord?> _validatedRecord(
    _FileResourcePaths paths, {
    required ResourceCacheKey key,
  }) async {
    await _ensureManifestLoaded();
    final id = _recordId(key);
    var record = _pendingTouches[id] ?? _records[id];
    if (record == null) {
      // Crash recovery: a payload and its per-entry journal may have been
      // promoted immediately before the compact manifest update.
      record = await _readRecord(paths.metadata);
      if (record != null && record.key == key) {
        _records[id] = record;
        _manifestDirty = true;
      }
    }
    if (record == null || record.key != key) {
      return null;
    }
    final expiresAt = record.expiresAt;
    if (expiresAt != null && !expiresAt.isAfter(_now())) {
      await _removePaths(paths, key: key);
      return null;
    }
    try {
      final stat = await paths.bytes.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size != record.byteLength) {
        await _removePaths(paths, key: key);
        return null;
      }
    } on FileSystemException {
      await _removePaths(paths, key: key);
      return null;
    }
    return record;
  }

  Future<void> _ensureManifestLoaded() {
    final existing = _manifestLoad;
    if (existing != null) {
      return existing;
    }
    final loading = _loadManifest();
    _manifestLoad = loading;
    return loading;
  }

  Future<void> _loadManifest() async {
    if (!await _root.exists()) {
      return;
    }
    final manifest = _manifestFile;
    var loaded = false;
    try {
      if (await manifest.exists()) {
        final decoded = jsonDecode(await manifest.readAsString());
        final records = decoded is Map<Object?, Object?>
            ? decoded['records']
            : null;
        if (decoded is Map<Object?, Object?> &&
            (decoded['formatVersion'] == _formatVersion ||
                decoded['formatVersion'] == _legacyFormatVersion) &&
            records is List) {
          for (final value in records) {
            if (value is! Map<Object?, Object?>) {
              throw const FormatException('invalid response manifest record');
            }
            final record = _FileResourceRecord.fromJson(
              value.cast<String, Object?>(),
            );
            _records[_recordId(record.key)] = record;
          }
          if (decoded['formatVersion'] == _legacyFormatVersion) {
            _manifestDirty = true;
          }
          loaded = true;
        }
      }
    } on FileSystemException {
      loaded = false;
    } on FormatException {
      loaded = false;
    }
    if (loaded) {
      return;
    }

    // One-time migration/recovery from the v42 per-entry metadata layout.
    _records.clear();
    final recoveredBytePaths = <String>{};
    final orphanCandidates = <File>[];
    await for (final entity in _root.list(recursive: true)) {
      if (entity is! File) {
        continue;
      }
      if (entity.path.endsWith('.bin')) {
        orphanCandidates.add(entity);
        continue;
      }
      if (!entity.path.endsWith('.json') || entity.path == manifest.path) {
        continue;
      }
      final paths = _pathsForMetadata(entity);
      final record = await _readRecord(entity);
      if (record != null) {
        _records[_recordId(record.key)] = record;
        recoveredBytePaths.add(paths.bytes.path);
      } else {
        await _deleteLegacyPaths(paths);
      }
    }
    for (final orphan in orphanCandidates) {
      if (!recoveredBytePaths.contains(orphan.path)) {
        try {
          await orphan.delete();
        } on FileSystemException {
          // A concurrently removed orphan is already clean.
        }
      }
    }
    _manifestDirty = true;
    await _flushManifest();
  }

  void _applyPendingTouches() {
    if (_pendingTouches.isEmpty) {
      return;
    }
    for (final entry in _pendingTouches.entries) {
      final current = _records[entry.key];
      if (current != null && current.key == entry.value.key) {
        _records[entry.key] = entry.value;
        _manifestDirty = true;
      }
    }
    _pendingTouches.clear();
  }

  Future<void> _flushManifest() async {
    _applyPendingTouches();
    if (!_manifestDirty) {
      return;
    }
    await _root.create(recursive: true);
    final temporary = File('${_manifestFile.path}.tmp');
    final records = _records.values.toList(growable: false)
      ..sort((left, right) => _recordId(left.key).compareTo(_recordId(right.key)));
    await temporary.writeAsString(
      jsonEncode(<String, Object?>{
        'formatVersion': _formatVersion,
        'records': records.map((record) => record.toJson()).toList(),
      }),
      flush: true,
    );
    await _replace(temporary, _manifestFile);
    _manifestDirty = false;
  }

  Future<_FileResourceRecord?> _readRecord(File metadata) async {
    try {
      if (!await metadata.exists()) {
        return null;
      }
      final decoded = jsonDecode(await metadata.readAsString());
      if (decoded is! Map<Object?, Object?>) {
        return null;
      }
      return _FileResourceRecord.fromJson(
        decoded.cast<String, Object?>(),
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _replace(File source, File target) async {
    if (await target.exists()) {
      await target.delete();
    }
    await source.rename(target.path);
  }

  Future<void> _removePaths(
    _FileResourcePaths paths, {
    required ResourceCacheKey key,
  }) async {
    final id = _recordId(key);
    _pendingTouches.remove(id);
    if (_records.remove(id) != null) {
      _manifestDirty = true;
    }
    for (final file in <File>[
      paths.metadata,
      paths.bytes,
      File('${paths.metadata.path}.tmp'),
      File('${paths.metadata.path}.touch.tmp'),
      File('${paths.bytes.path}.tmp'),
    ]) {
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } on FileSystemException {
        // Missing or concurrently cleaned cache files are already a miss.
      }
    }
  }

  _FileResourcePaths _paths(ResourceCacheKey key) {
    final digest = _keyHash(key);
    final directory = Directory('${_root.path}/${key.kind.name}');
    return _FileResourcePaths(
      bytes: File('${directory.path}/$digest.bin'),
      metadata: File('${directory.path}/$digest.json'),
    );
  }


  _FileResourcePaths _pathsForMetadata(File metadata) {
    final stem = metadata.path.substring(0, metadata.path.length - 5);
    return _FileResourcePaths(
      bytes: File('$stem.bin'),
      metadata: metadata,
    );
  }

  Future<void> _deleteLegacyPaths(_FileResourcePaths paths) async {
    for (final file in <File>[paths.metadata, paths.bytes]) {
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } on FileSystemException {
        // An invalid legacy pair is already a cache miss.
      }
    }
  }

  File get _manifestFile => File('${_root.path}/$_manifestName');

  String _recordId(ResourceCacheKey key) => '${key.kind.name}/${_keyHash(key)}';

  void _requireOpen() {
    if (_closed) {
      throw StateError('resource byte store is closed');
    }
  }
}

final class _FileResourceInventory {
  const _FileResourceInventory({
    required this.records,
    required this.totalBytes,
  });

  final List<_FileResourceCandidate> records;
  final int totalBytes;
}

final class _FileResourceCandidate {
  const _FileResourceCandidate({
    required this.paths,
    required this.record,
  });

  final _FileResourcePaths paths;
  final _FileResourceRecord record;
}

final class _FileResourcePaths {
  const _FileResourcePaths({
    required this.bytes,
    required this.metadata,
  });

  final File bytes;
  final File metadata;
}

final class _FileResourceRecord {
  const _FileResourceRecord({
    required this.key,
    required this.expiresAt,
    required this.retention,
    required this.lastAccessedAt,
    required this.byteLength,
    required this.contentHash,
  });

  final ResourceCacheKey key;
  final DateTime? expiresAt;
  final ResourceCacheRetention retention;
  final DateTime lastAccessedAt;
  final int byteLength;
  final String contentHash;

  _FileResourceRecord copyWith({
    DateTime? expiresAt,
    bool clearExpiresAt = false,
    ResourceCacheRetention? retention,
    DateTime? lastAccessedAt,
  }) =>
      _FileResourceRecord(
        key: key,
        expiresAt: clearExpiresAt ? null : expiresAt ?? this.expiresAt,
        retention: retention ?? this.retention,
        lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
        byteLength: byteLength,
        contentHash: contentHash,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'formatVersion': FileResourceCacheByteStore._formatVersion,
        'kind': key.kind.name,
        'identity': key.identity,
        'namespace': key.namespace,
        'revision': key.revision,
        'expiresAt': expiresAt?.toUtc().toIso8601String(),
        'retention': retention.name,
        'lastAccessedAt': lastAccessedAt.toUtc().toIso8601String(),
        'byteLength': byteLength,
        'contentHash': contentHash,
      };

  factory _FileResourceRecord.fromJson(Map<String, Object?> json) {
    final formatVersion = json['formatVersion'];
    if (formatVersion != FileResourceCacheByteStore._formatVersion &&
        formatVersion != FileResourceCacheByteStore._legacyFormatVersion) {
      throw const FormatException('unsupported resource cache record');
    }
    final kindName = json['kind'];
    final identity = json['identity'];
    final namespace = json['namespace'];
    final revision = json['revision'];
    final expiresAt = json['expiresAt'];
    final retentionName = json['retention'];
    final lastAccessedAt = json['lastAccessedAt'];
    final byteLength = json['byteLength'];
    final contentHash = json['contentHash'];
    if (kindName is! String ||
        identity is! String ||
        namespace is! String ||
        revision is! String ||
        (expiresAt != null && expiresAt is! String) ||
        (retentionName != null && retentionName is! String) ||
        lastAccessedAt is! String ||
        byteLength is! int ||
        contentHash is! String) {
      throw const FormatException('invalid resource cache record');
    }
    final kind = ResourceCacheKind.values.where(
      (candidate) => candidate.name == kindName,
    );
    if (kind.length != 1 || identity.isEmpty || byteLength < 0) {
      throw const FormatException('invalid resource cache identity');
    }
    final retentionMatches = retentionName == null
        ? const <ResourceCacheRetention>[]
        : ResourceCacheRetention.values
            .where((candidate) => candidate.name == retentionName)
            .toList(growable: false);
    if (retentionName != null && retentionMatches.length != 1) {
      throw const FormatException('invalid resource cache retention');
    }
    final effectiveRetention = retentionName == null
        ? ResourceCacheRetention.transient
        : retentionMatches.single;
    if (effectiveRetention == ResourceCacheRetention.transient &&
        expiresAt is! String) {
      throw const FormatException('transient resource cache record needs expiry');
    }
    return _FileResourceRecord(
      key: ResourceCacheKey(
        kind: kind.single,
        identity: identity,
        namespace: namespace,
        revision: revision,
      ),
      expiresAt: expiresAt is String ? DateTime.parse(expiresAt) : null,
      retention: effectiveRetention,
      lastAccessedAt: DateTime.parse(lastAccessedAt),
      byteLength: byteLength,
      contentHash: contentHash,
    );
  }
}

String _keyHash(ResourceCacheKey key) {
  final input = '${key.kind.name}\u0000${key.identity}\u0000'
      '${key.namespace}\u0000${key.revision}';
  final bytes = utf8.encode(input);
  final first = _fnv64(bytes, 0xcbf29ce484222325);
  final second = _fnv64(bytes, 0x84222325cbf29ce4);
  return '${first.toRadixString(16).padLeft(16, '0')}'
      '${second.toRadixString(16).padLeft(16, '0')}';
}

String _contentHash(Uint8List bytes) {
  final first = _fnv64(bytes, 0xcbf29ce484222325);
  final second = _fnv64(bytes, 0x84222325cbf29ce4);
  return '${first.toRadixString(16).padLeft(16, '0')}'
      '${second.toRadixString(16).padLeft(16, '0')}';
}

int _fnv64(Iterable<int> bytes, int seed) {
  const mask = 0xffffffffffffffff;
  var hash = seed & mask;
  for (final byte in bytes) {
    hash ^= byte & 0xff;
    hash = (hash * 0x100000001b3) & mask;
  }
  return hash;
}

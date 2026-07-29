import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:resource_cache/resource_cache.dart';

/// Atomic, bounded file backing for immutable response bytes such as covers.
///
/// The full cache key is persisted and verified on every read. Hashes are only
/// path selectors; a collision is treated as a miss rather than returning the
/// wrong response.
final class FileResourceCacheByteStore
    implements ResourceCacheByteStore, ResourceCacheByteStoreMaintenance {
  FileResourceCacheByteStore(
    String rootPath, {
    this.maxEntries = 96,
    this.maxBytes = 32 * 1024 * 1024,
    DateTime Function()? now,
  })  : assert(maxEntries > 0),
        assert(maxBytes > 0),
        _root = Directory(rootPath),
        _now = now ?? DateTime.now;

  static const int _formatVersion = 1;

  final Directory _root;
  final int maxEntries;
  final int maxBytes;
  final DateTime Function() _now;
  bool _closed = false;

  @override
  Future<PersistedResourceBytes?> read(ResourceCacheKey key) async {
    _requireOpen();
    final paths = _paths(key);
    final metadataExists = await paths.metadata.exists();
    final bytesExist = await paths.bytes.exists();
    if (!metadataExists || !bytesExist) {
      if (metadataExists || bytesExist) {
        await _deletePaths(paths);
      }
      return null;
    }
    try {
      final record = await _readRecord(paths.metadata);
      if (record == null) {
        await _deletePaths(paths);
        return null;
      }
      if (record.key != key) {
        return null;
      }
      final now = _now();
      if (!record.expiresAt.isAfter(now)) {
        await _deletePaths(paths);
        return null;
      }
      final bytes = await paths.bytes.readAsBytes();
      if (bytes.lengthInBytes != record.byteLength ||
          _contentHash(bytes) != record.contentHash) {
        await _deletePaths(paths);
        return null;
      }
      await _writeMetadata(
        paths.metadata,
        record.copyWith(lastAccessedAt: now),
      );
      return PersistedResourceBytes(
        bytes: bytes,
        expiresAt: record.expiresAt,
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      await _deletePaths(paths);
      return null;
    }
  }

  @override
  Future<void> write({
    required ResourceCacheKey key,
    required Uint8List bytes,
    required DateTime expiresAt,
  }) async {
    _requireOpen();
    if (!expiresAt.isAfter(_now())) {
      await remove(key);
      return;
    }
    await _root.create(recursive: true);
    final paths = _paths(key);
    await paths.bytes.parent.create(recursive: true);
    final now = _now();
    final record = _FileResourceRecord(
      key: key,
      expiresAt: expiresAt,
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
    await _trim();
  }

  @override
  Future<void> remove(ResourceCacheKey key) async {
    _requireOpen();
    await _deletePaths(_paths(key));
  }

  @override
  Future<void> removeWhere(
    bool Function(ResourceCacheKey key) predicate,
  ) async {
    _requireOpen();
    if (!await _root.exists()) {
      return;
    }
    await for (final entity in _root.list(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.json')) {
        continue;
      }
      final record = await _readRecord(entity);
      if (record != null && predicate(record.key)) {
        await _deletePaths(_pathsForMetadata(entity));
      }
    }
  }

  @override
  Future<ResourceCacheByteStoreUsage> inspect() async {
    _requireOpen();
    final inventory = await _inventory();
    return ResourceCacheByteStoreUsage(
      bytes: inventory.totalBytes,
      entries: inventory.records.length,
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
    final beforeBytes = inventory.totalBytes;
    var remainingBytes = beforeBytes;
    var evictedEntries = 0;
    for (final candidate in inventory.records) {
      if (remainingBytes <= targetBytes) {
        break;
      }
      await _deletePaths(candidate.paths);
      remainingBytes -= candidate.record.byteLength;
      evictedEntries++;
    }
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
  }

  @override
  Future<void> close() async {
    _closed = true;
  }

  Future<void> _trim() async {
    final inventory = await _inventory();
    var entries = inventory.records.length;
    var totalBytes = inventory.totalBytes;
    for (final candidate in inventory.records) {
      if (entries <= maxEntries && totalBytes <= maxBytes) {
        break;
      }
      await _deletePaths(candidate.paths);
      entries--;
      totalBytes -= candidate.record.byteLength;
    }
  }

  Future<_FileResourceInventory> _inventory() async {
    if (!await _root.exists()) {
      return const _FileResourceInventory(
        records: <_FileResourceCandidate>[],
        totalBytes: 0,
      );
    }
    final now = _now();
    final records = <_FileResourceCandidate>[];
    var totalBytes = 0;
    await for (final entity in _root.list(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.json')) {
        continue;
      }
      final record = await _readRecord(entity);
      final paths = _pathsForMetadata(entity);
      if (record == null ||
          !record.expiresAt.isAfter(now) ||
          !await paths.bytes.exists()) {
        await _deletePaths(paths);
        continue;
      }
      final actualLength = await paths.bytes.length();
      if (actualLength != record.byteLength) {
        await _deletePaths(paths);
        continue;
      }
      records.add(_FileResourceCandidate(paths: paths, record: record));
      totalBytes += actualLength;
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

  Future<void> _writeMetadata(
    File metadata,
    _FileResourceRecord record,
  ) async {
    final temporary = File('${metadata.path}.touch.tmp');
    await temporary.writeAsString(jsonEncode(record.toJson()), flush: true);
    await _replace(temporary, metadata);
  }

  Future<void> _replace(File source, File target) async {
    if (await target.exists()) {
      await target.delete();
    }
    await source.rename(target.path);
  }

  Future<void> _deletePaths(_FileResourcePaths paths) async {
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
    required this.lastAccessedAt,
    required this.byteLength,
    required this.contentHash,
  });

  final ResourceCacheKey key;
  final DateTime expiresAt;
  final DateTime lastAccessedAt;
  final int byteLength;
  final String contentHash;

  _FileResourceRecord copyWith({DateTime? lastAccessedAt}) =>
      _FileResourceRecord(
        key: key,
        expiresAt: expiresAt,
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
        'expiresAt': expiresAt.toUtc().toIso8601String(),
        'lastAccessedAt': lastAccessedAt.toUtc().toIso8601String(),
        'byteLength': byteLength,
        'contentHash': contentHash,
      };

  factory _FileResourceRecord.fromJson(Map<String, Object?> json) {
    if (json['formatVersion'] != FileResourceCacheByteStore._formatVersion) {
      throw const FormatException('unsupported resource cache record');
    }
    final kindName = json['kind'];
    final identity = json['identity'];
    final namespace = json['namespace'];
    final revision = json['revision'];
    final expiresAt = json['expiresAt'];
    final lastAccessedAt = json['lastAccessedAt'];
    final byteLength = json['byteLength'];
    final contentHash = json['contentHash'];
    if (kindName is! String ||
        identity is! String ||
        namespace is! String ||
        revision is! String ||
        expiresAt is! String ||
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
    return _FileResourceRecord(
      key: ResourceCacheKey(
        kind: kind.single,
        identity: identity,
        namespace: namespace,
        revision: revision,
      ),
      expiresAt: DateTime.parse(expiresAt),
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

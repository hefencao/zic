import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:network_bridge/network_bridge.dart';

import 'library_sync.dart';
import 'webdav_repository.dart';

const webDavSnapshotFormat = 'zic-library-sync-v3';
const _previousSnapshotFormat = 'zic-library-sync-v2';
const _indexLimit = 64 * 1024;
const _transferTimeout = Duration(minutes: 2);
final _digestPattern = RegExp(r'^[0-9a-f]{64}$');
final _snapshotPattern = RegExp(
  r'^backups/\d{4}-\d{2}-\d{2}/\d{8}T\d{12}Z-[0-9a-f]{16}\.json$');
final _dailyPattern = RegExp(r'^backups(?:-v3)?/\d{4}-\d{2}-\d{2}\.json$');
final _objectPattern = RegExp(r'^objects(?:-v3)?/\d{8}T\d{12}Z-[0-9a-f]{16}/[0-9a-f]{64}\.json\.gz$');

/// Latest is the sole mutable commit point. Immutable daily backups and gzip
/// objects are retained by a coordinated, bounded maintenance operation.
final class WebDavSnapshot {
  WebDavSnapshot(this.records, {this.etag, this.index});
  final Map<String, LibrarySyncRecord> records;
  final String? etag;
  final Map<String, Object?>? index;
  bool get legacy => index == null;
  bool get needsMigration => index?['format'] != webDavSnapshotFormat;
}

final class PreparedWebDavSnapshot {
  PreparedWebDavSnapshot(this.records, this.parts, this.matchesRemote);
  final Map<String, LibrarySyncRecord> records;
  final List<WebDavSnapshotPart> parts;
  final bool matchesRemote;
}

final class WebDavSnapshotPart {
  WebDavSnapshotPart(this.id, this.records, this.bytes, this.expandedBytes)
      : hash = sha256.convert(bytes).toString();
  final String id;
  final Map<String, LibrarySyncRecord> records;
  final List<int> bytes;
  final int expandedBytes;
  final String hash;
  Map<String, Object?> get descriptor => <String, Object?>{
    'id': id, 'hash': hash, 'bytes': bytes.length,
    'expandedBytes': expandedBytes, 'records': records.length,
  };
}

String _partition(LibrarySyncRecord record) {
  if (record.kind == 'progress' || record.kind == 'read') return 'activity';
  if (record.kind == 'reader' || record.kind == 'category' ||
      record.kind == 'setting' || record.kind == 'source') return 'settings';
  // Stable buckets keep a catalog edit from shifting every following chunk.
  return 'catalog-' + (int.parse(syncFingerprint(record.key)[0], radix: 16) % 4).toString();
}

Future<PreparedWebDavSnapshot> prepareWebDavSnapshot(
  Map<String, LibrarySyncRecord> local,
  Map<String, LibrarySyncRecord> remote, {bool forceParts = false}
) => Isolate.run(() {
  final edits = Map<String, LibrarySyncRecord>.of(local);
  // Plugin APIs do not expose the timestamp/default of old native settings.
  // An unedited first observation must adopt an already-published choice;
  // explicit UI edits and manual restores always have a positive clock.
  edits.removeWhere((key, record) => key.startsWith('setting:plugin\u0000') &&
    record.time == 0 && remote.containsKey(key));
  final records = mergeLibrarySync(edits, remote);
  // A fresh device's identical default is not a new edit. Adopt the published
  // register instead of producing a snapshot merely to change its writer id.
  for (final key in records.keys.toList(growable: false)) {
    final published = remote[key];
    if (published != null && records[key]!.time == published.time &&
        records[key]!.fingerprint == published.fingerprint) records[key] = published;
  }
  if (records.length > maxLibrarySyncRecords) {
    throw const LibrarySyncFormatException('同步记录数量超出上限');
  }
  final matches = records.length == remote.length && records.entries.every((entry) {
    final previous = remote[entry.key];
    return previous != null && entry.value.time == previous.time &&
        entry.value.writer == previous.writer && entry.value.fingerprint == previous.fingerprint;
  });
  if (matches && !forceParts) return PreparedWebDavSnapshot(records, [], true);
  final groups = <String, Map<String, LibrarySyncRecord>>{};
  for (final entry in records.entries) {
    (groups[_partition(entry.value)] ??= {})[entry.key] = entry.value;
  }
  var expanded = 0;
  var compressed = 0;
  final parts = <WebDavSnapshotPart>[];
  final ids = groups.keys.toList()..sort();
  for (final id in ids) {
    final values = groups[id]!;
    final plain = encodeLibrarySync(values, compress: false);
    expanded += plain.length;
    if (expanded > maxLibrarySyncBytes) {
      throw const LibrarySyncFormatException('同步数据超过 32 MiB');
    }
    final bytes = const MetadataGzipCodec().encode(plain);
    compressed += bytes.length;
    if (compressed > maxLibrarySyncBytes) {
      throw const LibrarySyncFormatException('同步数据超过 32 MiB');
    }
    parts.add(WebDavSnapshotPart(id, values, bytes, plain.length));
  }
  return PreparedWebDavSnapshot(records, parts, matches);
});

/// Protocol/storage adapter only. Library versions and merge/application remain
/// owned by WebDavSyncController. Every operation uses its injected NetLane.
final class WebDavSnapshots {
  WebDavSnapshots(this.client, {required this.checkActive,
    required this.message, required this.onRetry});
  final WebDavClient client;
  final void Function() checkActive;
  final void Function(String) message;
  final void Function(int) onRetry;
  String? _profile;
  Uri? _latest;
  WebDavSnapshot? _cached;
  final Map<String, WebDavSnapshotPart> _objects = {};
  int uploadedBytes = 0;
  String? maintenanceWarning;
  String? _backupDate;

  void _bind(WebDavConfig config, Uri latest) {
    if (_profile == config.identity && _latest == latest) return;
    _profile = config.identity;
    _latest = latest;
    _cached = null;
    _objects.clear();
    _backupDate = null;
  }

  void _retainObjects(Map<String, Object?> index) {
    final retained = <String>{for (final raw in index['parts']! as List)
      _objectPath(raw as Map)};
    _objects.removeWhere((path, _) => !retained.contains(path));
  }

  Future<WebDavSnapshot> read(WebDavConfig config, {bool requireLatest = false, Uri? latest}) async {
    final target = latest ?? config.latest;
    _bind(config, target);
    checkActive();
    final cached = _cached;
    final response = await client.request(config, 'GET', target,
      maxBytes: _indexLimit, onRetry: onRetry,
      headers: <String, String>{if (cached?.etag != null) 'If-None-Match': cached!.etag!});
    checkActive();
    if (response.status == 304 && cached != null) {
      _retainObjects(cached.index!);
      return cached;
    }
    WebDavClient.requireStatus(response, const {200, 404});
    if (response.status == 404) {
      if (requireLatest) {
        throw const WebDavException('最新同步索引缺失，请恢复云端最新版本后重试');
      }
      // Preserve the old file verbatim. Once v2 exists it is the only head;
      // old backups must never resurrect deletions into the current version.
      final legacy = await client.request(config, 'GET', config.file,
        requestTimeout: _transferTimeout, onRetry: onRetry);
      WebDavClient.requireStatus(legacy, const {200, 404});
      if (legacy.status == 200) webDavStrongEtag(legacy);
      final records = legacy.status == 404 ? <String, LibrarySyncRecord>{}
          : await Isolate.run(() => decodeLibrarySync(legacy.bytes));
      checkActive();
      return WebDavSnapshot(records);
    }
    final etag = webDavStrongEtag(response);
    final index = _decodeIndex(response.bytes);
    final records = <String, LibrarySyncRecord>{};
    var count = 0;
    _retainObjects(index);
    for (final raw in index['parts']! as List) {
      checkActive();
      final part = Map<String, Object?>.from(raw as Map);
      final path = _objectPath(part);
      final cachedPart = _objects[path];
      final WebDavSnapshotPart object;
      if (cachedPart == null) {
        final bytes = await client.request(config, 'GET',
          config.collection.resolve(path),
          maxBytes: part['bytes']! as int, requestTimeout: _transferTimeout, onRetry: onRetry);
        WebDavClient.requireStatus(bytes, const {200});
        object = await Isolate.run(() => _decodePart(bytes.bytes, part));
      } else {
        object = cachedPart;
      }
      if (object.records.length != part['records'] || object.id != part['id'] ||
          object.expandedBytes != part['expandedBytes'] || object.bytes.length != part['bytes']) {
        throw const LibrarySyncFormatException('同步分片与索引不一致');
      }
      for (final entry in object.records.entries) {
        if (records.containsKey(entry.key)) {
          throw const LibrarySyncFormatException('云端同步记录标识重复');
        }
        records[entry.key] = entry.value;
        if (++count % 256 == 0) await Future<void>.delayed(Duration.zero);
      }
      _objects[path] = object;
    }
    checkActive();
    return _cached = WebDavSnapshot(records, etag: etag, index: index);
  }

  Future<WebDavResponse> publish(WebDavConfig config, WebDavSnapshot previous,
    PreparedWebDavSnapshot prepared, WebDavRepositorySession session) async {
    _bind(config, session.latest);
    session.guard();
    final time = session.now.toUtc();
    final date = time.toIso8601String().substring(0, 10);
    final snapshot = 'backups/' + date + '.json';
    final directory = 'objects/' + session.generation + '/';
    final existingPaths = <String, String>{};
    for (final raw in previous.index?['parts'] as List? ?? const []) {
      final part = raw as Map;
      final path = _objectPath(part);
      if (_objectPattern.hasMatch(path) &&
          path.endsWith('/' + session.generation + '/' + (part['hash'] as String) + '.json.gz') &&
          _objects.containsKey(path)) existingPaths[part['hash'] as String] = path;
    }
    final paths = {for (final part in prepared.parts)
      part.hash: existingPaths[part.hash] ?? directory + part.hash + '.json.gz'};
    final index = <String, Object?>{
      'format': webDavSnapshotFormat, 'snapshot': snapshot,
      'createdAt': time.toIso8601String(),
      'parts': prepared.parts.map((part) => <String, Object?>{
        ...part.descriptor, 'object': paths[part.hash],
      }).toList(),
    };
    for (final directory in ['', 'objects/', directory, 'backups/']) {
      checkActive();
      await client.ensureCollection(config, uri: config.collection.resolve(directory), onRetry: onRetry);
    }
    for (var i = 0; i < prepared.parts.length; i++) {
      checkActive();
      final part = prepared.parts[i];
      final path = paths[part.hash]!;
      if (_objects.containsKey(path)) continue;
      message('正在上传同步分片（' + (i + 1).toString() + '/' +
        prepared.parts.length.toString() + '）…');
      final uri = config.collection.resolve(path);
      final response = await client.request(config, 'PUT', uri,
        headers: const {'If-None-Match': '*', 'Content-Type': 'application/gzip'},
        bytes: part.bytes, maxBytes: 256 * 1024,
        requestTimeout: _transferTimeout, onRetry: onRetry);
      if (response.status == 412) {
        // A preceding lost response may have created the object. The name
        // alone never proves that its actual bytes match our content digest.
        final existing = await client.request(config, 'GET', uri,
          maxBytes: part.bytes.length, requestTimeout: _transferTimeout, onRetry: onRetry);
        WebDavClient.requireStatus(existing, const {200});
        await Isolate.run(() => _decodePart(existing.bytes, part.descriptor));
      } else {
        WebDavClient.requireStatus(response, const {200, 201, 204}, reconcileWrite: true);
        uploadedBytes += part.bytes.length;
      }
      _objects[path] = part;
    }
    checkActive();
    final bytes = utf8.encode(jsonEncode(index));
    message('正在发布最新同步版本…');
    final head = await client.request(config, 'PUT', session.latest,
      headers: <String, String>{
        if (previous.etag == null) 'If-None-Match': '*' else 'If-Match': previous.etag!,
      }, bytes: bytes, maxBytes: 256 * 1024, onRetry: onRetry);
    if (head.status != 412) {
      WebDavClient.requireStatus(head, const {200, 201, 204}, reconcileWrite: true);
    }
    // Keep the committed snapshot for daily backup; next sync still GETs the
    // head because a successful PUT need not provide its new validator.
    _cached = head.status == 412 ? null : WebDavSnapshot(prepared.records, index: index);
    return head;
  }

  Future<void> maintain(WebDavConfig config, WebDavRepositorySession session) async {
    maintenanceWarning = null;
    try {
      session.guard();
      final date = session.now.toIso8601String().substring(0, 10);
      final path = 'backups/' + date + '.json';
      // One successful snapshot per UTC day, shared by every device. HEAD
      // avoids repeatedly sending even a small archive on unchanged syncs.
      if (_backupDate != date) {
        var exists = await client.request(config, 'HEAD', config.collection.resolve(path),
          maxBytes: 256 * 1024, onRetry: onRetry);
        WebDavClient.requireStatus(exists, const {200, 404});
        if (exists.status == 404) {
          exists = await client.request(config, 'HEAD',
            config.collection.resolve('backups-v3/' + date + '.json'), maxBytes: 256 * 1024, onRetry: onRetry);
          WebDavClient.requireStatus(exists, const {200, 404});
        }
        if (exists.status == 404) {
          final latest = _cached ?? await read(config, requireLatest: true, latest: session.latest);
          if (latest.needsMigration) return;
          session.guard();
          await client.ensureCollection(config,
            uri: config.collection.resolve('backups/'), onRetry: onRetry);
          session.guard();
          message('正在保存每日备份…');
          final archive = await client.request(config, 'PUT', config.collection.resolve(path),
            headers: const {'If-None-Match': '*'}, bytes: utf8.encode(jsonEncode(latest.index)),
            maxBytes: 256 * 1024, onRetry: onRetry);
          WebDavClient.requireStatus(archive, const {200, 201, 204, 412});
        }
        _backupDate = date;
      }
      session.guard();
      if (!await session.beginMaintenance()) return;
      message('正在整理云端备份…');
      await _collect(config, session);
      await session.finishMaintenance();
    } on Object {
      checkActive(); // Cancellation and session expiry must remain observable.
      maintenanceWarning = '云端备份整理未完成，将稍后重试';
    }
  }

  Future<void> _collect(WebDavConfig config, WebDavRepositorySession session) async {
    // Fence every pre-maintenance publisher before taking the root set. A
    // stale request cannot commit its old ETag after the epoch is changed.
    late WebDavSnapshot latest;
    var fenced = false;
    for (var attempt = 0; attempt < 3; attempt++) {
      _cached = null;
      latest = await read(config, requireLatest: true, latest: session.latest);
      session.guard();
      final fence = await client.request(config, 'PUT', session.latest,
        headers: {'If-Match': latest.etag!}, bytes: utf8.encode(jsonEncode({
          ...latest.index!, 'maintenanceEpoch': session.generation,
        })), maxBytes: 256 * 1024, onRetry: onRetry);
      if (fence.status == 412) continue;
      WebDavClient.requireStatus(fence, const {200, 201, 204});
      fenced = true;
      break;
    }
    if (!fenced) throw const WebDavException('最新同步版本发生变化，本次跳过整理');
    _cached = null;
    final files = <WebDavRepositoryFile>[];
    for (final directory in ['backups/', 'backups-v3/']) {
      files.addAll(await listWebDavRepository(client, config, directory, session.guard, onRetry,
        allowMissing: !(latest.index!['snapshot']! as String).startsWith(directory)));
    }
    final backups = <String, ({Map<String, Object?> index, String etag})>{};
    for (final file in files) {
      session.guard();
      if (file.collection || !_dailyPattern.hasMatch(file.path)) continue;
      final response = await client.request(config, 'GET', config.collection.resolve(file.path),
        maxBytes: _indexLimit, onRetry: onRetry);
      WebDavClient.requireStatus(response, const {200});
      final index = _decodeIndex(response.bytes);
      if (index['format'] != webDavSnapshotFormat) {
        throw const WebDavException('日期备份版本不符，本次跳过整理');
      }
      backups[file.path] = (index: index, etag: webDavStrongEtag(response));
      if (backups.length > 4096) throw const WebDavException('日期备份过多，本次跳过整理');
    }
    final keep = selectWebDavBackups(backups.keys, session.now);
    final protected = <String>{for (final raw in latest.index!['parts']! as List)
      _objectPath(raw as Map)};
    for (final entry in backups.entries) {
      if (keep.contains(entry.key)) {
        for (final raw in entry.value.index['parts']! as List) {
          protected.add(_objectPath(raw as Map));
        }
      }
    }
    // Complete and validate every directory before any destructive request.
    final candidates = <WebDavRepositoryFile>[];
    final generations = <WebDavRepositoryFile>[];
    for (final directory in ['objects/', 'objects-v3/']) {
      generations.addAll(await listWebDavRepository(client, config, directory, session.guard, onRetry,
        allowMissing: !protected.any((path) => path.startsWith(directory))));
    }
    final cutoff = session.now.subtract(const Duration(days: 7));
    for (final directory in generations) {
      if (!directory.collection || !directory.path.endsWith('/')) continue;
      final name = directory.path.split('/')[1];
      if (!webDavGenerationPattern.hasMatch(name) || name == session.generation ||
          name == session.previousGeneration || !webDavGenerationTime(name).isBefore(cutoff)) continue;
      final objects = await listWebDavRepository(client, config, directory.path, session.guard, onRetry);
      for (final object in objects) {
        if (!object.collection && _objectPattern.hasMatch(object.path) && !protected.contains(object.path)) {
          webDavStrongEtag(WebDavResponse(200, _emptyBytes, object.etag));
          candidates.add(object);
        }
      }
      if (candidates.length > 20000) throw const WebDavException('待整理分片过多，本次跳过整理');
    }
    for (final entry in backups.entries) {
      if (!keep.contains(entry.key)) await _delete(config, entry.key, entry.value.etag, session);
    }
    for (final file in candidates) {
      await _delete(config, file.path, file.etag!, session);
    }
  }

  Future<void> _delete(WebDavConfig config, String path, String etag,
    WebDavRepositorySession session) async {
    session.guard();
    final response = await client.request(config, 'DELETE', config.collection.resolve(path),
      headers: {'If-Match': etag}, maxBytes: 256 * 1024, onRetry: onRetry);
    WebDavClient.requireStatus(response, const {200, 204, 404});
  }
}

final _emptyBytes = utf8.encode('');
String _objectPath(Map part) => part['object'] as String? ?? 'objects/' + (part['hash'] as String) + '.json.gz';

Map<String, Object?> _decodeIndex(List<int> bytes) {
  final raw = jsonDecode(utf8.decode(bytes));
  if (raw is! Map || !const {webDavSnapshotFormat, _previousSnapshotFormat}.contains(raw['format']) ||
      raw['snapshot'] is! String ||
      !(raw['format'] == webDavSnapshotFormat ? _dailyPattern : _snapshotPattern)
        .hasMatch(raw['snapshot'] as String) ||
      raw['createdAt'] is! String || DateTime.tryParse(raw['createdAt'] as String) == null ||
      raw['parts'] is! List || (raw['parts'] as List).length > 6) {
    throw const LibrarySyncFormatException('云端同步索引无效或版本不受支持');
  }
  final ids = <String>{};
  var expanded = 0;
  var compressed = 0;
  var count = 0;
  for (final value in raw['parts'] as List) {
    if (value is! Map || value['id'] is! String ||
        !const {'activity', 'settings', 'catalog-0', 'catalog-1', 'catalog-2', 'catalog-3'}
          .contains(value['id']) || !ids.add(value['id'] as String) ||
        value['hash'] is! String || !_digestPattern.hasMatch(value['hash'] as String) ||
        value['bytes'] is! int || (value['bytes'] as int) < 1 ||
        (value['bytes'] as int) > maxLibrarySyncBytes ||
        value['expandedBytes'] is! int || (value['expandedBytes'] as int) < 1 ||
        value['records'] is! int || (value['records'] as int) < 1 ||
        (raw['format'] == webDavSnapshotFormat &&
          (value['object'] is! String || !_objectPattern.hasMatch(value['object'] as String) ||
            !(value['object'] as String).endsWith('/' + (value['hash'] as String) + '.json.gz'))) ||
        (raw['format'] == _previousSnapshotFormat && value['object'] != null)) {
      throw const LibrarySyncFormatException('云端同步分片索引无效');
    }
    expanded += value['expandedBytes'] as int;
    compressed += value['bytes'] as int;
    count += value['records'] as int;
    if (expanded > maxLibrarySyncBytes || compressed > maxLibrarySyncBytes ||
        count > maxLibrarySyncRecords) {
      throw const LibrarySyncFormatException('云端同步数据超过允许上限');
    }
  }
  return Map<String, Object?>.from(raw);
}

WebDavSnapshotPart _decodePart(List<int> bytes, Map<String, Object?> part) {
  if (bytes.length != part['bytes'] || sha256.convert(bytes).toString() != part['hash']) {
    throw const LibrarySyncFormatException('云端同步分片校验失败');
  }
  try {
    final plain = const MetadataGzipCodec().decode(bytes, maxBytes: part['expandedBytes']! as int);
    if (plain.length != part['expandedBytes']) {
      throw const LibrarySyncFormatException('云端同步分片长度不符');
    }
    final records = decodeLibrarySync(plain);
    if (records.length != part['records'] ||
        records.values.any((record) => _partition(record) != part['id'])) {
      throw const LibrarySyncFormatException('同步分片与索引不一致');
    }
    return WebDavSnapshotPart(part['id']! as String, records, bytes, plain.length);
  } on MetadataGzipLimitException {
    throw const LibrarySyncFormatException('云端同步分片解压超限');
  }
}

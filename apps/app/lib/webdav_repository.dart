import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:network_bridge/network_bridge.dart';
import 'package:xml/xml.dart';

final webDavGenerationPattern = RegExp(r'^\d{8}T\d{12}Z-[0-9a-f]{16}$');
const _leaseLifetime = Duration(minutes: 15);
const _operationLifetime = Duration(minutes: 10);

String webDavGeneration(DateTime time) {
  final stamp = time.toUtc().toIso8601String().replaceAll(RegExp(r'[-:.]'), '');
  final padded = stamp.substring(0, stamp.length - 1).padRight(21, '0') + 'Z';
  final random = Random.secure();
  return padded + '-' + List.generate(8, (_) => random.nextInt(256)
    .toRadixString(16).padLeft(2, '0')).join();
}

DateTime webDavGenerationTime(String generation) => DateTime.parse(
  generation.substring(0, 8) + 'T' + generation.substring(9, 15) + '.' +
    generation.substring(15, 21) + 'Z');

String webDavStrongEtag(WebDavResponse response) {
  final etag = response.etag?.trim();
  if (etag == null || etag.length < 2 || etag.startsWith('W/') ||
      !etag.startsWith('"') || !etag.endsWith('"') || etag.contains(RegExp(r'[\r\n]'))) {
    throw const WebDavException('服务器未提供可用于安全合并的文件版本，请使用支持 ETag 的 WebDAV 服务');
  }
  return etag;
}

/// Repository CAS coordination, not a network scheduler. Every request still
/// enters the injected NetLane. Shared sessions protect readers and writers;
/// maintenance upgrades only when no other live session is present.
final class WebDavRepositorySession {
  WebDavRepositorySession._(this.client, this.config, this.checkActive,
    this.onRetry, this.token, this._serverTime, this._uri);
  final WebDavClient client;
  final WebDavConfig config;
  final void Function() checkActive;
  final void Function(int) onRetry;
  final String token;
  final DateTime _serverTime;
  final Uri _uri;
  late final Uri latest;
  final _elapsed = Stopwatch()..start();
  late String generation;
  String? previousGeneration;
  bool _closed = false;
  late int _maintenanceAfter;
  DateTime get now => _serverTime.add(_elapsed.elapsed);

  void guard() {
    checkActive();
    if (_closed || _elapsed.elapsed >= _operationLifetime) {
      throw const WebDavException('同步会话已到期，请重新同步');
    }
  }

  static Future<WebDavRepositorySession> open(WebDavClient client, WebDavConfig config,
    {required void Function() checkActive, required void Function(int) onRetry}) async {
    final token = webDavGeneration(DateTime.now().toUtc());
    var uri = config.collection.resolve('repository.json');
    // An existing v3 repository keeps its one coordination/head pair. Copying
    // that mutable register to a second name would split concurrent writers.
    checkActive();
    var response = await client.request(config, 'GET', uri, maxBytes: 64 * 1024, onRetry: onRetry);
    checkActive();
    WebDavClient.requireStatus(response, const {200, 404});
    if (response.status == 404) {
      final old = await client.request(config, 'GET', config.collection.resolve('repository-v3.json'),
        maxBytes: 64 * 1024, onRetry: onRetry);
      checkActive();
      WebDavClient.requireStatus(old, const {200, 404});
      if (old.status == 200) { uri = config.collection.resolve('repository-v3.json'); response = old; }
    }
    var head = 'latest.json';
    if (response.status == 404) {
      final old = await client.request(config, 'HEAD', config.legacyLatest,
        maxBytes: 256 * 1024, onRetry: onRetry);
      checkActive();
      WebDavClient.requireStatus(old, const {200, 404});
      if (old.status == 200) head = 'latest-v2.json';
    }
    for (var attempt = 0; attempt < 5; attempt++) {
      checkActive();
      if (attempt != 0) {
        response = await client.request(config, 'GET', uri, maxBytes: 64 * 1024, onRetry: onRetry);
      }
      checkActive();
      WebDavClient.requireStatus(response, const {200, 404});
      final serverTime = response.date?.toUtc();
      if (serverTime == null) throw const WebDavException('WebDAV 未提供服务器时间，无法安全协调多端同步');
      final session = WebDavRepositorySession._(client, config, checkActive, onRetry, token, serverTime, uri);
      final state = response.status == 404 ? <String, Object?>{
        'format': 'zic-repository-v3', 'generation': webDavGeneration(serverTime),
        'head': head,
        'maintenanceAfter': serverTime.add(const Duration(days: 7)).millisecondsSinceEpoch,
        'sessions': <String, Object?>{},
      } : session._decode(response.bytes);
      session.latest = config.collection.resolve(state['head'] as String? ?? 'latest-v2.json');
      final sessions = session._liveSessions(state);
      if (state['maintenance'] != null && sessions.containsKey(state['maintenance'])) {
        throw const WebDavException('其他设备正在整理云端备份，请稍后同步');
      }
      if (sessions.length >= 64) throw const WebDavException('正在同步的设备过多，请稍后重试');
      state.remove('maintenance');
      sessions[token] = session.now.add(_leaseLifetime).millisecondsSinceEpoch;
      state['sessions'] = sessions;
      final written = await session._write(state,
        response.status == 404 ? null : webDavStrongEtag(response));
      if (const {404, 409}.contains(written.status) && response.status == 404) {
        await client.ensureCollection(config, onRetry: onRetry);
        continue;
      }
      if (written.status == 412) continue;
      WebDavClient.requireStatus(written, const {200, 201, 204});
      session.generation = state['generation']! as String;
      session._maintenanceAfter = state['maintenanceAfter']! as int;
      session.guard();
      return session;
    }
    throw const WebDavException('云端同步会话正在变化，请稍后重试');
  }

  Map<String, Object?> _decode(List<int> bytes) {
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map || value['format'] != 'zic-repository-v3' ||
        value['generation'] is! String || !webDavGenerationPattern.hasMatch(value['generation'] as String) ||
        value['sessions'] is! Map || (value['sessions'] as Map).length > 64 ||
        value['maintenanceAfter'] is! int ||
        (value['head'] != null && !const {'latest.json', 'latest-v2.json'}.contains(value['head'])) ||
        (value['maintenance'] != null && value['maintenance'] is! String)) {
      throw const WebDavException('云端同步协调信息无效，未执行修改');
    }
    for (final entry in (value['sessions'] as Map).entries) {
      if (entry.key is! String || !webDavGenerationPattern.hasMatch(entry.key as String) ||
          entry.value is! int || (entry.value as int) < 0) {
        throw const WebDavException('云端同步会话无效，未执行修改');
      }
    }
    return Map<String, Object?>.from(value);
  }

  Map<String, Object?> _liveSessions(Map<String, Object?> state) => <String, Object?>{
    for (final entry in (state['sessions']! as Map).entries)
      if ((entry.value as int) > now.millisecondsSinceEpoch) entry.key as String: entry.value,
  };

  Future<WebDavResponse> _write(Map<String, Object?> state, String? etag,
    {Duration? timeout, bool quiet = false}) async {
    final bytes = utf8.encode(jsonEncode(state));
    try {
      final response = await client.request(config, 'PUT', _uri,
        headers: {if (etag == null) 'If-None-Match': '*' else 'If-Match': etag},
        bytes: bytes, maxBytes: 256 * 1024, requestTimeout: timeout,
        onRetry: quiet ? null : onRetry);
      WebDavClient.requireStatus(response, const {200, 201, 204, 404, 409, 412}, reconcileWrite: true);
      return response;
    } on WebDavException catch (error) {
      if (!error.requiresReadBeforeRetry ||
          (error.retryAfter != null && error.retryAfter! > Duration.zero)) rethrow;
      checkActive();
      final actual = await client.request(config, 'GET', _uri,
        maxBytes: 64 * 1024, requestTimeout: timeout, onRetry: quiet ? null : onRetry);
      WebDavClient.requireStatus(actual, const {200, 404});
      // Confirm the exact committed register; otherwise let the caller merge
      // a fresh control document instead of replaying an obsolete CAS body.
      if (actual.status == 200 && utf8.decode(actual.bytes) == utf8.decode(bytes)) return actual;
      return WebDavResponse(412, utf8.encode(''), null);
    }
  }

  Future<bool> beginMaintenance() async {
    guard();
    if (_maintenanceAfter > now.millisecondsSinceEpoch) return false;
    for (var attempt = 0; attempt < 5; attempt++) {
      final response = await client.request(config, 'GET', _uri, maxBytes: 64 * 1024, onRetry: onRetry);
      WebDavClient.requireStatus(response, const {200});
      guard();
      final state = _decode(response.bytes);
      if ((state['maintenanceAfter']! as int) > now.millisecondsSinceEpoch) return false;
      final sessions = _liveSessions(state);
      if (sessions.length != 1 || !sessions.containsKey(token)) return false;
      previousGeneration = state['generation']! as String;
      final nextGeneration = webDavGeneration(now);
      state['generation'] = nextGeneration;
      state['sessions'] = sessions;
      state['maintenance'] = token;
      // A failed maintenance is retried after an hour, not on every sync.
      state['maintenanceAfter'] = now.add(const Duration(hours: 1)).millisecondsSinceEpoch;
      final written = await _write(state, webDavStrongEtag(response));
      if (written.status == 412) continue;
      WebDavClient.requireStatus(written, const {200, 201, 204});
      generation = nextGeneration;
      return true;
    }
    return false;
  }

  Future<void> finishMaintenance() async {
    guard();
    final response = await client.request(config, 'GET', _uri, maxBytes: 64 * 1024, onRetry: onRetry);
    WebDavClient.requireStatus(response, const {200});
    final state = _decode(response.bytes);
    guard();
    if (state['maintenance'] != token) throw const WebDavException('云端整理会话已变化');
    state['maintenanceAfter'] = now.add(const Duration(days: 7)).millisecondsSinceEpoch;
    final written = await _write(state, webDavStrongEtag(response));
    WebDavClient.requireStatus(written, const {200, 201, 204});
  }

  Future<void> close({bool abandon = false}) async {
    if (_closed) return;
    _closed = true;
    if (abandon) return; // Cancellation drains immediately; the pin expires.
    try {
      for (var attempt = 0; attempt < 3; attempt++) {
        checkActive();
        final response = await client.request(config, 'GET', _uri,
          maxBytes: 64 * 1024, requestTimeout: const Duration(seconds: 5));
        WebDavClient.requireStatus(response, const {200});
        final state = _decode(response.bytes);
        final sessions = Map<String, Object?>.from(state['sessions']! as Map);
        if (!sessions.containsKey(token)) return;
        sessions.remove(token);
        state['sessions'] = sessions;
        if (state['maintenance'] == token) state.remove('maintenance');
        checkActive();
        final written = await _write(state, webDavStrongEtag(response),
          timeout: const Duration(seconds: 5), quiet: true);
        if (written.status == 412) continue;
        return;
      }
    } on Object { /* Expiry preserves safety after a lost acknowledgement. */ }
  }
}

final class WebDavRepositoryFile {
  WebDavRepositoryFile(this.path, this.etag, this.collection);
  final String path;
  final String? etag;
  final bool collection;
}

Future<List<WebDavRepositoryFile>> listWebDavRepository(WebDavClient client,
  WebDavConfig config, String directory, void Function() guard,
  void Function(int) onRetry, {bool allowMissing = false}) async {
  guard();
  final uri = config.collection.resolve(directory);
  final response = await client.request(config, 'PROPFIND', uri,
    headers: const {'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8'},
    bytes: utf8.encode('<d:propfind xmlns:d="DAV:"><d:prop><d:getetag/>'
      '<d:resourcetype/></d:prop></d:propfind>'), maxBytes: 8 * 1024 * 1024, onRetry: onRetry);
  if (allowMissing && response.status == 404) return [];
  WebDavClient.requireStatus(response, const {207});
  guard();
  return Isolate.run(() => _decodeListing(response.bytes, config.collection, uri));
}

List<WebDavRepositoryFile> _decodeListing(List<int> bytes, Uri root, Uri directory) {
  final document = XmlDocument.parse(utf8.decode(bytes));
  if (document.rootElement.name.local != 'multistatus' ||
      document.rootElement.namespaceUri != 'DAV:' ||
      document.descendants.any((node) => node is XmlDoctype)) {
    throw const WebDavException('云端目录响应无效，未清理文件');
  }
  final result = <WebDavRepositoryFile>[];
  final seen = <String>{};
  var foundDirectory = false;
  for (final response in document.rootElement.findElements('response', namespace: 'DAV:')) {
    final href = response.getElement('href', namespace: 'DAV:')?.innerText;
    if (href == null) throw const WebDavException('云端目录项目缺少地址，未清理文件');
    final uri = directory.resolve(href);
    if (uri.origin != root.origin || uri.hasQuery || uri.hasFragment || uri.userInfo.isNotEmpty ||
        !uri.path.startsWith(directory.path)) {
      throw const WebDavException('云端目录项目越界，未清理文件');
    }
    final suffix = uri.path.substring(directory.path.length);
    if (suffix.replaceFirst(RegExp(r'/$'), '').contains('/') ||
        suffix.contains('%') || !seen.add(uri.path)) {
      throw const WebDavException('云端目录层级或项目重复，未清理文件');
    }
    final properties = <XmlElement>[];
    for (final propstat in response.findElements('propstat', namespace: 'DAV:')) {
      final status = propstat.getElement('status', namespace: 'DAV:')?.innerText ?? '';
      if (!RegExp(r'^HTTP/\d(?:\.\d)? 200(?: |$)').hasMatch(status.trim())) {
        throw const WebDavException('云端目录属性不完整，未清理文件');
      }
      final prop = propstat.getElement('prop', namespace: 'DAV:');
      if (prop != null) properties.add(prop);
    }
    if (properties.isEmpty) throw const WebDavException('云端目录属性缺失，未清理文件');
    String? etag;
    var collection = false;
    for (final prop in properties) {
      etag ??= prop.getElement('getetag', namespace: 'DAV:')?.innerText;
      collection = collection || prop.getElement('resourcetype', namespace: 'DAV:')
          ?.getElement('collection', namespace: 'DAV:') != null;
    }
    if (suffix.isEmpty) {
      if (!collection) throw const WebDavException('云端目录自身属性不完整，未清理文件');
      foundDirectory = true;
      continue;
    }
    result.add(WebDavRepositoryFile(uri.path.substring(root.path.length), etag, collection));
    if (result.length > 20000) throw const WebDavException('云端目录过大，本次跳过整理');
  }
  if (!foundDirectory) throw const WebDavException('云端目录响应不完整，未清理文件');
  return result;
}

/// Selection is repository-wide, never multiplied by the number of devices.
Set<String> selectWebDavBackups(Iterable<String> paths, DateTime now) {
  final dates = paths.toList()..sort((a, b) {
    final date = b.substring(b.lastIndexOf('/') + 1).compareTo(a.substring(a.lastIndexOf('/') + 1));
    return date != 0 ? date : a.length.compareTo(b.length);
  });
  final result = <String>{};
  final days = <String>{};
  final weeks = <String>{};
  final months = <String>{};
  for (final path in dates) {
    final match = RegExp(r'^backups(?:-v3)?/(\d{4}-\d{2}-\d{2})\.json$').firstMatch(path);
    if (match == null) throw const WebDavException('云端日期备份名称无效，未清理文件');
    final text = match[1]!;
    final date = DateTime.tryParse(text + 'T00:00:00Z');
    if (date == null || date.toIso8601String().substring(0, 10) != text) {
      throw const WebDavException('云端日期备份名称无效，未清理文件');
    }
    // Do not expire a future date on a device/server clock correction.
    if (date.isAfter(now.toUtc())) { result.add(path); continue; }
    final week = date.subtract(Duration(days: date.weekday - 1)).toIso8601String().substring(0, 10);
    final month = text.substring(0, 7);
    var keep = false;
    if (!days.contains(text) && days.length < 7) { days.add(text); keep = true; }
    if (!weeks.contains(week) && weeks.length < 4) { weeks.add(week); keep = true; }
    if (!months.contains(month) && months.length < 12) { months.add(month); keep = true; }
    if (keep) result.add(path);
  }
  return result;
}

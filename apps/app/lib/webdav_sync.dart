import 'dart:async';
import 'dart:math';

import 'package:network_bridge/network_bridge.dart';
import 'package:catalog/catalog.dart';
import 'package:flutter/foundation.dart';
import 'package:storage_bridge/storage_bridge.dart';

import 'app_preferences.dart';
import 'library_sync.dart';
import 'library_data_scope.dart';
import 'portable_settings.dart';
import 'webdav_repository.dart';
import 'webdav_snapshots.dart';

typedef SyncJsonRead = Future<Map<String, Object?>?> Function(String name);
typedef SyncJsonWrite = Future<void> Function(String name, Map<String, Object?> data);

final class WebDavSyncResult {
  const WebDavSyncResult(this.completedAt, this.records, this.pending);
  final DateTime completedAt;
  final int records;
  final int pending;
}

/// Manual, single-flight synchronization. Construction performs no storage or
/// network work and never joins the Home/Reader startup critical path.
final class WebDavSyncController extends ChangeNotifier {
  WebDavSyncController({
    required this.client,
    required this.preferences,
    required this.readLibrary,
    required this.applyLibrary,
    required Future<String> Function() storageRoot,
    this.portableSettings,
    SyncJsonRead? read,
    SyncJsonWrite? write,
    DateTime Function()? now,
  }) : _read = read ?? ((name) async =>
           readJsonObjectFile(await storageRoot() + '/webdav/' + name)),
       _write = write ?? ((name, data) async =>
           writeJsonObjectFile(await storageRoot() + '/webdav/' + name, data)),
       _now = now ?? DateTime.now;

  final WebDavClient client;
  final AppPreferencesController preferences;
  final PortableSettingsOwner? portableSettings;
  final Future<ImportedLibraryBackupSnapshot> Function() readLibrary;
  final Future<void> Function(
    List<LibrarySyncRecord> records,
    Map<String, LibrarySyncValue> expected,
  ) applyLibrary;
  final SyncJsonRead _read;
  final SyncJsonWrite _write;
  final DateTime Function() _now;
  late final _snapshots = WebDavSnapshots(client, checkActive: _checkActive,
    message: _setMessage, onRetry: _networkRetry);
  Future<void>? _initialization;
  Future<void>? _operation;
  Future<void>? _closeFuture;
  Completer<void>? _retryWake;
  final Map<String, Map<String, Object?>> _versions = {};
  final Map<String, LibrarySyncRecord> _pendingImports = {};
  String _device = '';
  String? _profile;
  bool _closed = false;
  bool _cancelled = false;
  bool _busy = false;
  bool _version2 = false;
  WebDavRepositorySession? _repositorySession;
  WebDavConfig? _config;
  Set<LibraryDataSection> _sections = Set.of(allLibraryDataSections);
  WebDavSyncResult? _lastResult;
  String? _error;
  String? _message;
  String _dataStage = '本机同步状态';

  WebDavConfig? get config => _config;
  Set<LibraryDataSection> get sections => Set.unmodifiable(_sections);
  bool get busy => _busy;
  WebDavSyncResult? get lastResult => _lastResult;
  String? get error => _error;
  String? get message => _message;

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    final configJson = await _read('connection.json');
    final state = await _read('state.json');
    final pending = await _read('pending-imports.json');
    final pendingRecords = pending?['records'];
    if (pendingRecords != null) {
      if (pendingRecords is! List || pendingRecords.length > maxLibrarySyncRecords) {
        throw const LibrarySyncFormatException('待恢复进度记录无效');
      }
      for (final raw in pendingRecords) {
        final record = LibrarySyncRecord.fromJson(Map<String, Object?>.from(raw as Map));
        if (record.kind != 'progress' || record.deleted || _pendingImports.containsKey(record.key)) {
          throw const LibrarySyncFormatException('待恢复进度记录无效');
        }
        _pendingImports[record.key] = record;
      }
    }
    if (configJson != null && configJson['address'] is String) {
      _config = WebDavConfig(
        address: configJson['address']! as String,
        username: (configJson['username'] as String?) ?? '',
        password: (configJson['password'] as String?) ?? '',
      );
      final sections = configJson['sections'];
      if (sections != null) {
        if (sections is! List || sections.isEmpty || sections.any((value) =>
            !LibraryDataSection.values.any((section) => section.name == value))) {
          throw const FormatException('同步数据范围无效');
        }
        _sections = {for (final name in sections) LibraryDataSection.values.byName(name as String)};
      }
    }
    final device = state?['device'];
    _device = device is String && device.isNotEmpty
        ? device : List.generate(16, (_) => Random.secure().nextInt(256)
            .toRadixString(16).padLeft(2, '0')).join();
    _profile = state?['profile'] as String?;
    if (_profile != null &&
        (_config == null || _profile == syncFingerprint(_config!.identity))) {
      _version2 = const {2, 3}.contains(state?['remoteProtocol']);
      final versions = state?['versions'];
      if (versions is Map) {
        if (versions.length > maxLibrarySyncRecords) {
          throw const FormatException('本机同步版本记录超出上限');
        }
        for (final entry in versions.entries) {
          final value = Map<String, Object?>.from(entry.value as Map);
          if (value['hash'] is! String || value['time'] is! int ||
              value['writer'] is! String) {
            throw const FormatException('本机同步版本记录损坏');
          }
          _versions[entry.key as String] = value;
        }
      }
      final completed = state?['completedAt'];
      if (completed is String) {
        _lastResult = WebDavSyncResult(DateTime.parse(completed),
          (state?['records'] as int?) ?? 0, 0);
      }
    }
    _notify();
  }

  Future<void> saveConfiguration(WebDavConfig config, {Set<LibraryDataSection>? sections}) {
    if (_busy) throw const WebDavException('请等待当前同步操作完成');
    final selected = Set<LibraryDataSection>.of(sections ?? _sections);
    if (selected.isEmpty) throw const WebDavException('请至少选择一类同步数据');
    return _run(() => _saveConfiguration(config, selected));
  }

  Future<void> _saveConfiguration(WebDavConfig config, Set<LibraryDataSection> sections) async {
    _checkActive();
    _setMessage('正在保存连接信息…');
    await _write('connection.json', {...config.toJson(),
      'sections': [for (final section in LibraryDataSection.values) if (sections.contains(section)) section.name]});
    _config = config;
    _sections = sections;
    final profile = syncFingerprint(config.identity);
    if (_profile != profile) {
      _versions.clear();
      _lastResult = null;
      _version2 = false;
      _profile = profile;
    }
    await _saveState();
    _error = null;
    _message = '连接信息已保存';
    _notify();
  }

  Future<void> disconnect() {
    if (_busy) throw const WebDavException('请等待当前同步操作完成');
    return _run(() async {
      await _write('connection.json', <String, Object?>{'version': 1});
      _config = null;
      _sections = Set.of(allLibraryDataSections);
      _message = '本机连接配置已移除';
    });
  }

  Future<void> testConnection() => _run(() async {
    _setMessage('正在测试连接…');
    await client.testConnection(_requireConfig(), onRetry: _networkRetry);
    _setMessage('连接成功');
  });

  Future<void> synchronize() => _run(_synchronize);

  Future<Map<String, LibrarySyncRecord>> exportRecords({
    Set<LibraryDataSection> sections = allLibraryDataSections,
  }) async {
    if (_busy) throw const WebDavException('请等待当前操作完成');
    final selected = Set<LibraryDataSection>.of(sections);
    if (selected.isEmpty) throw const WebDavException('请至少选择一类导出数据');
    late Map<String, LibrarySyncRecord> records;
    await _run(() async {
      _setMessage('正在准备备份…');
      records = await _capture(await _localValues(selected), selected);
      _validateSettings(records.values);
      await _saveState();
      _message = null;
    });
    return records;
  }

  Future<void> _run(Future<void> Function() work) {
    final operation = _operation;
    if (operation != null) return operation;
    if (_closed) return Future.error(const WebDavException('同步已关闭'));
    _busy = true;
    _cancelled = false;
    _error = null;
    _dataStage = '本机同步状态';
    _notify();
    late final Future<void> next;
    next = (() async {
      try {
        await initialize();
        _checkActive();
        await work();
      } on Object catch (error) {
        _message = null;
        _error = error is WebDavException ? error.toString()
            : error is FormatException ? _dataStage + '格式无效，同步已停止' +
                (error is LibrarySyncFormatException ? '：' + error.message : '')
            : '同步失败，请检查网络或本机存储后重试';
        rethrow;
      } finally {
        _busy = false;
        _operation = null;
        _notify();
      }
    })();
    _operation = next;
    return next;
  }

  WebDavConfig _requireConfig() =>
      _config ?? (throw const WebDavException('请先保存 WebDAV 连接信息'));

  Future<Map<String, LibrarySyncValue>> _localValues(Set<LibraryDataSection> sections) async {
    _checkActive();
    _dataStage = '本机数据';
    var snapshot = await readLibrary();
    final reading = sections.contains(LibraryDataSection.readingSettings)
        ? preferences.readSyncReadingSettings() : <String, Object?>{};
    final times = sections.contains(LibraryDataSection.readingSettings)
        ? preferences.syncReadingTimes : <String, int>{};
    var values = selectLibraryData(await prepareLibrarySyncValues(snapshot, reading, times), sections);
    if (sections.contains(LibraryDataSection.history) && _pendingImports.isNotEmpty) {
      final before = _pendingImports.length;
      // A new local reading action supersedes an older pending restore.
      _pendingImports.removeWhere((key, record) =>
        (values[key]?.initialTime ?? 0) > record.time);
      await applyLibrary(_pendingImports.values.toList(), values);
      _checkActive();
      snapshot = await readLibrary();
      values = selectLibraryData(await prepareLibrarySyncValues(snapshot, reading, times), sections);
      _pendingImports.removeWhere((key, record) => values[key]?.fingerprint == record.fingerprint);
      if (_pendingImports.length != before) await _savePendingImports();
      // Keep unavailable-file progress in the next export/sync; it is not
      // discarded merely because this device has not imported the files yet.
      for (final entry in _pendingImports.entries) {
        values[entry.key] = LibrarySyncValue(entry.value.data, entry.value.time);
      }
    }
    values.addAll(await portableSettings?.read(sections: sections) ?? {});
    _checkActive();
    return values;
  }

  Future<Map<String, LibrarySyncRecord>> _capture(
    Map<String, LibrarySyncValue> values,
    Set<LibraryDataSection> sections,
  ) async {
    _dataStage = '本机版本记录';
    final now = _now().toUtc().microsecondsSinceEpoch;
    final defaults = AppPreferencesController();
    final defaultReading = defaults.readSyncReadingSettings();
    defaultReading.addAll(portableSettings?.defaults ?? {});
    defaults.dispose();
    final captured = await captureLibrarySync(
      values, selectLibraryData(_versions, sections), _device, now, defaultReading);
    _checkActive();
    if (_versions.length + captured.versions.keys.where((key) => !_versions.containsKey(key)).length >
        maxLibrarySyncRecords) {
      throw const LibrarySyncFormatException('同步记录数量超出上限');
    }
    _versions.addAll(captured.versions);
    return captured.records;
  }

  Future<void> _synchronize() async {
    final config = _requireConfig();
    final sections = Set<LibraryDataSection>.of(_sections);
    _setMessage('正在读取本机数据…');
    final values = await _localValues(sections);
    final records = await _capture(values, sections);
    // Persist deletion/version intent before even the session-registration IO.
    await _saveState();
    _checkActive();
    _dataStage = '云端同步协调信息';
    final session = await WebDavRepositorySession.open(client, config,
      checkActive: _checkCancellation, onRetry: _networkRetry);
    _repositorySession = session;
    try {
      await _synchronizeSession(config, session, values, records, sections);
    } finally {
      _repositorySession = null;
      await session.close(abandon: _cancelled || _closed);
    }
  }

  Future<void> _synchronizeSession(WebDavConfig config, WebDavRepositorySession session,
    Map<String, LibrarySyncValue> initialValues, Map<String, LibrarySyncRecord> initialRecords,
    Set<LibraryDataSection> sections) async {
    _snapshots.uploadedBytes = 0;
    var conflicts = 0;
    var recoveries = 0;
    var first = true;
    while (true) {
      _setMessage('正在读取本机数据…');
      final localValues = first ? initialValues : await _localValues(sections);
      final local = first ? initialRecords : await _capture(localValues, sections);
      // Deletion/version intent survives a failed upload or process exit.
      if (!first) await _saveState();
      first = false;
      _checkActive();
      _setMessage(recoveries > 0 ? '正在核对云端写入结果…'
          : conflicts > 0 ? '检测到并发变更，正在重新合并…' : '正在读取云端数据…');
      _dataStage = '云端数据';
      final remote = await _snapshots.read(config, requireLatest: _version2, latest: session.latest);
      if (!remote.legacy && !_version2) {
        _version2 = true;
        await _saveState();
      }
      _dataStage = '合并数据';
      final prepared = await prepareWebDavSnapshot(local, remote.records, forceParts: remote.needsMigration);
      _checkActive();
      final selected = selectLibraryData(prepared.records, sections);
      _validateSettings(selected.values);
      // A lost PUT response may already have committed. Read and merge first;
      // matching records confirm completion without another write. First v2
      // publication migrates the legacy file without modifying or deleting it.
      if (remote.needsMigration || !prepared.matchesRemote) {
        _setMessage('正在写回云端…');
        try {
          final uploaded = await _snapshots.publish(config, remote, prepared, session);
          if (uploaded.status == 412) {
            if (++conflicts >= 3) {
              throw const WebDavException('云端正被其他设备修改，请稍后再次同步');
            }
            continue;
          }
          _version2 = true;
          await _saveState();
        } on WebDavException catch (error) {
          if (!error.requiresReadBeforeRetry || recoveries >= 2 ||
              (error.retryAfter ?? Duration.zero) > const Duration(seconds: 30)) rethrow;
          await _waitForWriteRecovery(++recoveries, error.retryAfter);
          continue;
        }
      }
      _checkActive();
      _setMessage('正在更新本机数据…');
      await _applyRecords(selected, localValues);
      final actual = await _localValues(sections);
      var pending = sections.contains(LibraryDataSection.history) ? _pendingImports.length : 0;
      for (final record in selected.values) {
        final hash = actual[record.key]?.fingerprint ?? syncFingerprint(null);
        final evictedSetting = record.kind == 'reader' && !record.deleted &&
            actual[record.key] == null;
        if (hash == record.fingerprint || evictedSetting) {
          _versions[record.key] = <String, Object?>{
            'hash': record.fingerprint, 'time': record.time, 'writer': record.writer,
          };
        } else {
          pending++;
        }
      }
      _lastResult = WebDavSyncResult(_now().toUtc(),
        selected.values.where((record) => !record.deleted).length, pending);
      await _saveState();
      await _snapshots.maintain(config, session);
      _checkActive();
      final uploaded = _snapshots.uploadedBytes;
      final detail = uploaded == 0 ? '，无分片需要上传'
          : '，已上传压缩分片 ' + (uploaded / 1024).toStringAsFixed(1) + ' KiB';
      final warning = _snapshots.maintenanceWarning;
      final plugins = sections.contains(LibraryDataSection.extensions) ? portableSettings?.pendingPlugins ?? 0 : 0;
      final pluginDetail = plugins == 0 ? '' : '；' + plugins.toString() + ' 项插件设置等待对应插件可用后恢复';
      final storageDetail = preferences.downloadDirectorySetupRequired ? '；请在设置→数据中配置下载目录与访问授权' : '';
      _setMessage(pending == 0 ? '同步完成' + detail + pluginDetail + storageDetail + (warning == null ? '' : '；' + warning)
          : '同步完成，部分进度等待本机文件或后续合并');
      return;
    }
  }

  void _validateSettings(Iterable<LibrarySyncRecord> records) {
    _dataStage = '设置';
    for (final record in records) {
      validateSyncRecord(record);
      if (record.kind == 'reader' && record.data != null) {
        AppPreferencesController.validateSyncReadingSettings(record.identity, record.data!);
      } else if (record.kind == 'setting') {
        if (portableSettings == null) throw const FormatException('设置恢复服务不可用');
        PortableSettingsOwner.validate(record.key, record.data);
      }
    }
    portableSettings?.validateRecords(records.where((record) => record.kind == 'setting'));
  }

  Future<void> _applyRecords(Map<String, LibrarySyncRecord> records,
    Map<String, LibrarySyncValue> localValues) async {
    final changes = records.values.where((record) =>
      record.kind != 'reader' && record.kind != 'setting' &&
      record.fingerprint != syncFingerprint(localValues[record.key]?.data)).toList();
    if (changes.isNotEmpty) await applyLibrary(changes, localValues);
    _checkActive();
    final reading = records.values.where((record) => record.kind == 'reader').toList()
      ..sort((a, b) => a.time != b.time ? a.time.compareTo(b.time) : a.key.compareTo(b.key));
    for (final record in reading) {
      final known = _versions[record.key];
      if (!localValues.containsKey(record.key) && known != null &&
          record.time <= (known['time']! as int)) continue;
      final current = preferences.readSyncReadingSetting(record.key);
      if (syncFingerprint(current) == syncFingerprint(localValues[record.key]?.data) &&
          syncFingerprint(current) != record.fingerprint) {
        preferences.applySyncReadingSettings(record.identity, record.data, modifiedAt: record.time);
      }
    }
    await portableSettings?.apply(records.values.where((record) => record.kind == 'setting' &&
      record.fingerprint != syncFingerprint(localValues[record.key]?.data)).toList(), localValues);
    await preferences.flush();
  }

  /// Explicit restore is a new local edit. Missing backup records do not delete
  /// anything; selected records override older local/cloud clocks on next sync.
  Future<void> importRecords(Map<String, LibrarySyncRecord> records, {
    Set<LibraryDataSection> sections = allLibraryDataSections,
  }) {
    if (_busy) throw const WebDavException('请等待当前操作完成');
    final selected = Set<LibraryDataSection>.of(sections);
    final imported = selectLibraryData(records, selected);
    if (imported.isEmpty) throw const WebDavException('没有选中可导入的数据');
    return _run(() async {
      _validateSettings(imported.values);
      _setMessage('正在导入备份…');
      final values = await _localValues(selected);
      final current = await _capture(values, selected);
      final changes = <String, LibrarySyncRecord>{};
      final now = _now().toUtc().microsecondsSinceEpoch;
      for (final entry in imported.entries) {
        final time = max(now, max(entry.value.time, current[entry.key]?.time ?? 0) + 1);
        changes[entry.key] = restoreLibrarySyncRecord(entry.value, time, _device);
      }
      await _applyRecords(changes, values);
      final restored = await prepareLibrarySyncValues(await readLibrary(), const {});
      for (final record in changes.values) {
        if (record.kind == 'progress' && !record.deleted &&
            restored[record.key] == null) {
          _pendingImports[record.key] = record;
        }
      }
      await _savePendingImports();
      final actual = await _localValues(selected);
      for (final entry in changes.entries) {
        final value = actual[entry.key];
        // The owner may have normalized an embedded metadata timestamp.
        if (value == null && !entry.value.deleted) continue;
        _versions[entry.key] = {'hash': value?.fingerprint ?? syncFingerprint(null),
          'time': entry.value.time, 'writer': _device};
      }
      await _saveState();
      final plugins = selected.contains(LibraryDataSection.extensions) ? portableSettings?.pendingPlugins ?? 0 : 0;
      _setMessage('已导入 ' + imported.length.toString() + ' 项记录' +
        (_pendingImports.isEmpty ? '' : '，' + _pendingImports.length.toString() + ' 项进度等待对应本地漫画，后续导出或同步时恢复') +
        (plugins == 0 ? '' : '，' + plugins.toString() + ' 项插件设置等待对应插件可用后恢复') +
        (preferences.downloadDirectorySetupRequired ? '，请在设置→数据中配置下载目录与访问授权' : ''));
    });
  }

  Future<void> _savePendingImports() => _write('pending-imports.json', {
    'version': 1, 'records': _pendingImports.values.map((record) => record.toJson()).toList(),
  });

  void _networkRetry(int attempt) =>
      _setMessage('网络暂时中断，正在重试（' + attempt.toString() + '/' +
        WebDavClient.maxAttempts.toString() + '）…');

  Future<void> _waitForWriteRecovery(int attempt, Duration? retryAfter) async {
    _checkActive();
    _setMessage('上传连接中断，正在重新核对云端（' + attempt.toString() + '/2）…');
    final backoff = Duration(seconds: attempt);
    final delay = retryAfter != null && retryAfter > backoff ? retryAfter : backoff;
    final wake = Completer<void>();
    _retryWake = wake;
    final timer = Timer(delay, () => wake.complete());
    try {
      // Cancellation can be requested synchronously by a status listener.
      _checkActive();
      await wake.future;
    } finally {
      timer.cancel();
      _retryWake = null;
    }
    _checkActive();
  }

  void _wakeRetry() {
    final wake = _retryWake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  Future<void> _saveState() => _write('state.json', <String, Object?>{
    'version': 1, 'device': _device, 'profile': _profile,
    if (_version2) 'remoteProtocol': 3,
    'versions': _versions,
    if (_lastResult != null) 'completedAt': _lastResult!.completedAt.toIso8601String(),
    if (_lastResult != null) 'records': _lastResult!.records,
  });

  void _setMessage(String message) {
    _message = message;
    _notify();
  }

  void _checkActive() {
    _checkCancellation();
    _repositorySession?.guard();
  }

  void _checkCancellation() {
    if (_closed || _cancelled) throw const WebDavException('同步已取消');
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> cancel() async {
    if (_operation == null) return;
    _cancelled = true;
    _wakeRetry();
    await client.cancel();
    final operation = _operation;
    if (operation != null) {
      try { await operation; } on Object { /* The operation reports its error. */ }
    }
  }

  Future<void> close() => _closeFuture ??= (() async {
    _closed = true;
    _wakeRetry();
    await client.close();
    final operation = _operation;
    if (operation != null) {
      try { await operation; } on Object { /* Already reported by the owner. */ }
    }
    final initialization = _initialization;
    if (initialization != null) {
      try { await initialization; } on Object { /* No new work is admitted. */ }
    }
  })();
}

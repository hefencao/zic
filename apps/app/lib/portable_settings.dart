import 'dart:convert';

import 'package:catalog/catalog.dart';
import 'package:comic_translation/comic_translation.dart';
import 'package:downloads/downloads.dart';

import 'app_preferences.dart';
import 'extension_repositories.dart';
import 'library_sync.dart';
import 'library_data_scope.dart';

/// Explicit backup/sync composition. Feature owners keep their own persistence;
/// this adapter never scans arbitrary plugin files, cookies or secret stores.
final class PortableSettingsOwner {
  PortableSettingsOwner({
    required this.preferences,
    required this.loadTranslation,
    required this.sources,
    required this.readPluginState,
    required this.writePluginState,
    required this.readDownloadPolicy,
    required this.updateDownloadPolicy,
  });

  final AppPreferencesController preferences;
  final Future<ComicTranslationSettings> Function() loadTranslation;
  final Future<List<BrowsableComicSource>> Function() sources;
  final Future<Map<String, Object?>?> Function() readPluginState;
  final Future<void> Function(Map<String, Object?>) writePluginState;
  final WholeComicQueuePolicy Function() readDownloadPolicy;
  final Future<void> Function(WholeComicQueuePolicy) updateDownloadPolicy;
  final Map<String, Map<String, Object?>> _plugins = {};
  Future<void>? _initialization;
  Future<void> _writeTail = Future<void>.value();
  final Map<String, Future<void>> _restores = {};
  List<BrowsableComicSource> _sources = [];
  Map<String, Object?> defaults = {};
  int pendingPlugins = 0;

  Future<void> _initialize() => _initialization ??= (() async {
    final saved = await readPluginState();
    final entries = saved?['entries'];
    if (entries == null) return;
    if (entries is! Map || entries.length > 10000) {
      throw const FormatException('插件设置记录无效');
    }
    for (final entry in entries.entries) {
      final key = entry.key as String;
      final data = Map<String, Object?>.from(entry.value as Map);
      validate(key, Map<String, Object?>.from(data['data'] as Map));
      if (!key.startsWith('setting:plugin\u0000') || data['time'] is! int ||
          (data['time']! as int) < 0 || data['pending'] is! bool) {
        throw const FormatException('插件设置记录无效');
      }
      _plugins[key] = data;
    }
  })();

  Future<void> _persistPlugins() {
    final payload = <String, Object?>{'version': 1,
      'entries': jsonDecode(jsonEncode(_plugins))};
    final next = _writeTail.then((_) => writePluginState(payload));
    _writeTail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  static String pluginKey(String sourceId, String key) =>
      'setting:plugin\u0000' + jsonEncode([sourceId, key]);

  static bool canTransferPlugin(ComicSourceSetting setting) =>
      !setting.sensitive && setting.kind != ComicSourceSettingKind.action &&
      !RegExp(r'password|passwd|token|cookie|secret|api.?key|密码|令牌', caseSensitive: false)
        .hasMatch(setting.key + ' ' + setting.title);

  /// Called after a successful user command, including edits before first sync.
  Future<void> rememberPluginChange(String sourceId, ComicSourceSetting setting, Object value) async {
    if (!canTransferPlugin(setting)) return;
    await _initialize();
    final key = pluginKey(sourceId, setting.key);
    final data = <String, Object?>{'kind': setting.kind.name, 'value': value};
    validate(key, data);
    _plugins[key] = {'data': data,
      'time': DateTime.now().toUtc().microsecondsSinceEpoch, 'pending': false};
    await _persistPlugins();
  }

  Future<void> restorePluginSettings(BrowsableComicSource source) =>
      _restores[source.sourceId] ??= _restorePluginSettings(source).whenComplete(() {
        _restores.remove(source.sourceId);
      });

  Future<void> _restorePluginSettings(BrowsableComicSource source) async {
    await _initialize();
    if (source is! ConfigurableComicSource || !_plugins.entries.any((entry) =>
        entry.value['pending'] == true && _pair(_identity(entry.key)[1])[0] == source.sourceId)) return;
    for (final setting in await (source as ConfigurableComicSource).loadSettings()) {
      final pending = _plugins[pluginKey(source.sourceId, setting.key)];
      if (pending?['pending'] != true) continue;
      final data = Map<String, Object?>.from(pending!['data']! as Map);
      if (!_compatible(setting, data)) continue;
      await (source as ConfigurableComicSource).updateSetting(setting.key, data['value']!);
      pending['pending'] = false;
    }
    await _persistPlugins();
  }

  Future<Map<String, LibrarySyncValue>> read({
    Set<LibraryDataSection> sections = allLibraryDataSections,
  }) async {
    final result = <String, LibrarySyncValue>{};
    defaults = {};
    if (sections.contains(LibraryDataSection.appSettings)) {
      final defaultPreferences = AppPreferencesController();
      defaults.addAll({
        'setting:app\u0000global': defaultPreferences.readPortableSettings(),
        'setting:download\u0000policy': const WholeComicQueuePolicy().toJson(),
        'setting:storage\u0000download': {'access': 'app'},
      });
      defaultPreferences.dispose();
      result.addAll({
        'setting:app\u0000global': LibrarySyncValue(preferences.readPortableSettings(), 0),
        'setting:download\u0000policy': LibrarySyncValue(readDownloadPolicy().toJson(), 0),
        'setting:storage\u0000download': LibrarySyncValue({'access': preferences.downloadAccessPreference}, 0),
      });
    }
    if (sections.contains(LibraryDataSection.translation)) {
      final translation = await loadTranslation();
      final defaultTranslation = ComicTranslationSettings();
      defaults['setting:translation\u0000global'] = defaultTranslation.values;
      defaultTranslation.dispose();
      for (final entry in translation.readPortableSettings().entries) {
        result['setting:translation\u0000' + entry.key] =
          LibrarySyncValue(entry.value, translation.portableModifiedAt[entry.key] ?? 0);
      }
      for (final entry in translation.portableModifiedAt.entries) {
        final key = 'setting:translation\u0000' + entry.key;
        if (!result.containsKey(key)) result[key] = LibrarySyncValue(null, entry.value);
      }
    }
    if (sections.contains(LibraryDataSection.extensions)) await _readExtensions(result);
    for (final entry in result.entries) {
      if (entry.key.startsWith('setting:repository\u0000')) defaults[entry.key] = entry.value.data;
      validate(entry.key, entry.value.data);
    }
    return result;
  }

  Future<void> _readExtensions(Map<String, LibrarySyncValue> result) async {
    await _initialize();
    for (final entry in preferences.extensionRepositoryRecords.entries) {
      result['setting:repository\u0000' + entry.key] =
        LibrarySyncValue(entry.value, preferences.extensionRepositoryTimes[entry.key] ?? 0);
    }
    final before = syncFingerprint(_plugins);
    _sources = await sources();
    pendingPlugins = 0;
    for (final source in _sources) {
      if (source is! ConfigurableComicSource) continue;
      final List<ComicSourceSetting> settings;
      try {
        settings = await (source as ConfigurableComicSource).loadSettings();
      } on Object {
        continue; // Keep the last snapshot; an unavailable source is not deletion.
      }
      for (final setting in settings) {
        final key = pluginKey(source.sourceId, setting.key);
        if (!canTransferPlugin(setting)) {
          _plugins.remove(key);
          continue;
        }
        final previous = _plugins[key];
        final data = <String, Object?>{'kind': setting.kind.name, 'value': setting.value};
        if (previous?['pending'] == true) {
          final desired = Map<String, Object?>.from(previous!['data']! as Map);
          if (!_compatible(setting, desired)) continue;
          try {
            if (syncFingerprint(data) != syncFingerprint(desired)) {
              await (source as ConfigurableComicSource).updateSetting(setting.key, desired['value']!);
            }
          } on Object {
            continue;
          }
          previous['pending'] = false;
        } else {
          _plugins[key] = {'data': data, 'pending': false,
            'time': previous == null ? 0 : syncFingerprint(previous['data']) == syncFingerprint(data)
              ? previous['time'] : DateTime.now().toUtc().microsecondsSinceEpoch};
        }
      }
    }
    for (final entry in _plugins.entries) {
      final data = Map<String, Object?>.from(entry.value['data']! as Map);
      result[entry.key] = LibrarySyncValue(data, entry.value['time']! as int);
      // A fresh plugin's unedited defaults must not replace an existing remote
      // choice. The first publisher establishes its clock after reading head.
      defaults[entry.key] = data;
      if (entry.value['pending'] == true) pendingPlugins++;
    }
    if (before != syncFingerprint(_plugins)) await _persistPlugins();
  }

  static List<String> _identity(String key) {
    if (!key.startsWith('setting:')) throw const FormatException('无效的设置标识');
    final parts = key.substring('setting:'.length).split('\u0000');
    if (parts.length != 2 || parts.any((part) => part.isEmpty)) {
      throw const FormatException('无效的设置标识');
    }
    return parts;
  }

  static List<String> _pair(String identity) {
    final parts = jsonDecode(identity);
    if (parts is! List || parts.length != 2 ||
        parts.any((part) => part is! String || part.isEmpty) || jsonEncode(parts) != identity) {
      throw const FormatException('无效的插件设置标识');
    }
    return parts.cast<String>();
  }

  static void validate(String key, Map<String, Object?>? data) {
    final parts = _identity(key);
    if (parts[0] == 'repository') {
      ExtensionRepository.parse(parts[1], data);
    } else if (parts[0] == 'translation') {
      if (data == null && parts[1] != 'global') {
        _pair(parts[1]);
        return;
      }
      if (data == null) throw const FormatException('全局翻译设置不可删除');
      ComicTranslationSettings.validatePortableSettings(parts[1], data);
    } else if (parts[0] == 'app' && parts[1] == 'global' && data != null) {
      AppPreferencesController.validatePortableSettings(data);
    } else if (parts[0] == 'storage' && parts[1] == 'download' && data != null) {
      if (data.length != 1 || !{'app', 'saf', 'direct'}.contains(data['access'])) {
        throw const FormatException('无效的下载访问方式');
      }
    } else if (parts[0] == 'download' && parts[1] == 'policy' && data != null) {
      if (syncFingerprint(WholeComicQueuePolicy.fromJson(data).toJson()) != syncFingerprint(data)) {
        throw const FormatException('无效的下载策略');
      }
    } else if (parts[0] == 'plugin' && data != null) {
      final pair = _pair(parts[1]);
      final kind = data['kind'];
      final value = data['value'];
      if (RegExp(r'password|passwd|token|cookie|secret|api.?key|密码|令牌', caseSensitive: false)
          .hasMatch(pair[1]) || data.length != 2 ||
          !{'toggle', 'text', 'select', 'multiSelect'}.contains(kind) ||
          (kind == 'toggle' ? value is! bool : kind == 'multiSelect'
            ? value is! List || value.length > 5000 || value.any((item) => item is! String || item.length > 65536)
            : value is! String || value.length > 65536)) {
        throw const FormatException('无效或不可迁移的插件设置');
      }
    } else {
      throw const FormatException('未知或不可删除的设置');
    }
  }

  static bool _compatible(ComicSourceSetting setting, Map<String, Object?> data) {
    if (!canTransferPlugin(setting) || data['kind'] != setting.kind.name) return false;
    final choices = setting.choices.map((choice) => choice.value).toSet();
    return setting.kind == ComicSourceSettingKind.select ? choices.contains(data['value'])
        : setting.kind == ComicSourceSettingKind.multiSelect
          ? (data['value']! as List).every(choices.contains) : true;
  }

  Future<Map<String, Object?>?> _current(String key) async {
    final parts = _identity(key);
    switch (parts[0]) {
      case 'app': return preferences.readPortableSettings();
      case 'download': return readDownloadPolicy().toJson();
      case 'storage': return {'access': preferences.downloadAccessPreference};
      case 'translation': return (await loadTranslation()).readPortableSettings()[parts[1]];
      case 'repository': return preferences.extensionRepositoryRecords[parts[1]];
      case 'plugin':
        final pair = _pair(parts[1]);
        for (final source in _sources) {
          if (source.sourceId != pair[0] || source is! ConfigurableComicSource) continue;
          try {
            for (final setting in await (source as ConfigurableComicSource).loadSettings()) {
              if (setting.key == pair[1] && canTransferPlugin(setting)) {
                return {'kind': setting.kind.name, 'value': setting.value};
              }
            }
          } on Object { break; }
        }
        final stored = _plugins[key]?['data'];
        return stored == null ? null : Map<String, Object?>.from(stored as Map);
    }
    return null;
  }

  void validateRecords(Iterable<LibrarySyncRecord> records) {
    final repositories = <String>[];
    for (final record in records) validate(record.key, record.data);
    for (final record in records) {
      final parts = _identity(record.key);
      if (parts[0] == 'repository') repositories.add(parts[1]);
    }
    preferences.validateExtensionRepositoryCapacity(repositories);
  }

  Future<void> apply(List<LibrarySyncRecord> records, Map<String, LibrarySyncValue> expected) async {
    // Validate the whole batch before any feature owner's mutation.
    validateRecords(records);
    var pluginsChanged = false;
    for (final record in records) {
      final current = await _current(record.key);
      if (syncFingerprint(current) != syncFingerprint(expected[record.key]?.data) ||
          syncFingerprint(current) == record.fingerprint) continue;
      final parts = _identity(record.key);
      switch (parts[0]) {
        case 'app': preferences.applyPortableSettings(record.data!);
        case 'download': await updateDownloadPolicy(WholeComicQueuePolicy.fromJson(record.data!));
        case 'storage': preferences.restoreDownloadAccessPreference(record.data!['access']! as String);
        case 'translation': await (await loadTranslation()).applyPortableSettings(parts[1], record.data);
        case 'repository': preferences.applyExtensionRepository(parts[1], record.data, modifiedAt: record.time);
        case 'plugin':
          _plugins[record.key] = {'data': record.data, 'time': record.time, 'pending': true};
          await _persistPlugins();
          pluginsChanged = true;
      }
    }
    await preferences.flush();
    // Apply deferred plugin values only after they are durable and only through
    // the source's declared settings contract, never through opaque files.
    if (pluginsChanged) await read(sections: {LibraryDataSection.extensions});
  }
}

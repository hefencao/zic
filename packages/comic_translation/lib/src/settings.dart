import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Non-secret preferences. API keys belong exclusively to the secrets store.
final class ComicTranslationSettings extends ChangeNotifier {
  ComicTranslationSettings();

  static final instance = ComicTranslationSettings();
  static const _ocrKeys = {'ocrMaxAnalysisSide', 'ocrDetectionThreshold',
    'ocrRecognitionThreshold', 'ocrUnclipRatio'};
  static const _comicKeys = {'enabled', 'sourceLanguage', 'translateSoundEffects',
    'useCleanOverlay', 'showIndicator', 'indicatorOnlyWhileProcessing', ..._ocrKeys};
  final Map<String, Object?> values = {
    'comicTranslationSetupCompleted': false,
    'comicTranslationBackend': 'none',
    'comicTranslationLocalModel': '',
    'comicTranslationRemoteEndpoint': 'https://api.openai.com/v1/chat/completions',
    'comicTranslationRemoteModel': '',
    'comicTranslationAdditionalPrompt': '',
    'comicTranslationRemoteProfiles': <Object?>[],
    'comicTranslationRemoteProfile': 'default',
    'sourceLanguage': 'auto',
    'targetLanguage': 'zh-CN',
    'contextPages': 2,
    'translationQuality': 'balanced',
    'translationPrefetchPages': 4,
    'translationCachePrefetchPages': 4,
    'ocrMaxAnalysisSide': 1600,
    'ocrDetectionThreshold': .45,
    'ocrRecognitionThreshold': .35,
    'ocrUnclipRatio': 1.4,
    'translateSoundEffects': false,
    'useCleanOverlay': true,
    'showIndicator': true,
    'indicatorOnlyWhileProcessing': true,
    'enabled': false,
  };
  final Map<String, Map<String, Object?>> _comics = {};
  final Map<String, ({String language, String modelVersion})> _detectedLanguages = {};
  late File _file;
  Future<void> _tail = Future<void>.value();
  Future<void>? _initialization;
  final Map<String, int> _modifiedAt = {};
  Map<String, String> _portableBaseline = {};
  final Map<String, String> _credentialServices = {};

  Future<void> init(String directory) => _initialization ??= _init(directory);

  Future<void> _init(String directory) async {
    await Directory(directory).create(recursive: true);
    _file = File('$directory/comic_translation_settings.json');
    final temporary = File('${_file.path}.tmp');
    if (!await _file.exists() && await temporary.exists()) {
      await temporary.rename(_file.path);
    }
    if (!await _file.exists()) {
      _rememberExistingCredentialServices();
      _capturePortableBaseline();
      return;
    }
    final json = jsonDecode(await _file.readAsString()) as Map;
    final saved = Map<String, Object?>.from(json['settings'] as Map? ?? {});
    for (final key in values.keys.toList()) {
      if (saved.containsKey(key)) values[key] = saved[key];
    }
    final comics = json['comics'] as Map? ?? {};
    for (final entry in comics.entries) {
      _comics[entry.key as String] = Map<String, Object?>.from(entry.value as Map);
    }
    final languages = json['detectedLanguages'] as Map? ?? {};
    for (final entry in languages.entries) {
      final value = entry.value as Map;
      _detectedLanguages[entry.key as String] = (
        language: value['language'] as String, modelVersion: value['modelVersion'] as String);
    }
    final times = json['modifiedAt'] as Map? ?? {};
    for (final entry in times.entries) {
      if (entry.key is String && entry.value is int && entry.value >= 0) {
        _modifiedAt[entry.key as String] = entry.value as int;
      }
    }
    final services = json['credentialServices'];
    if (services is Map) {
      for (final entry in services.entries) {
        if (entry.key is String && entry.value is String) {
          _credentialServices[entry.key as String] = entry.value as String;
        }
      }
    } else {
      // Migrate bindings from the current local configuration before any
      // portable configuration can replace it. No key is read or exported.
      _rememberExistingCredentialServices();
    }
    _capturePortableBaseline();
  }

  static String _service(String backend, String endpoint) => jsonEncode([backend, endpoint.trim()]);

  void _rememberExistingCredentialServices() {
    final profiles = values['comicTranslationRemoteProfiles'] as List;
    for (final raw in profiles) {
      if (raw is Map && raw['id'] is String && raw['endpoint'] is String) {
        approveCredentialService(raw['id'] as String,
          raw['backend'] as String? ?? 'openaiCompatible', raw['endpoint'] as String);
      }
    }
    _credentialServices.putIfAbsent('default', () => _service('openaiCompatible',
      values['comicTranslationRemoteEndpoint'] as String));
  }

  bool permitsCredentialService(String profileId, String backend, String endpoint) =>
      _credentialServices[profileId] == _service(backend, endpoint);

  /// Only the explicit service form calls this when the user supplies a key.
  /// Portable application and per-comic edits cannot grant credential access.
  void approveCredentialService(String profileId, String backend, String endpoint) {
    _credentialServices[profileId] = _service(backend, endpoint);
  }

  Map<String, Map<String, Object?>> readPortableSettings() => {
    'global': {...values,
      'comicTranslationRemoteProfiles': [for (final raw in values['comicTranslationRemoteProfiles']! as List)
        _portableProfile(Map<String, Object?>.from(raw as Map))],
    },
    for (final entry in _comics.entries)
      entry.key: {for (final value in entry.value.entries)
        if (_comicKeys.contains(value.key)) value.key: value.value},
  };

  static Map<String, Object?> _portableProfile(Map<String, Object?> raw) => {
    'id': raw['id'], 'backend': raw['backend'] ?? 'openaiCompatible',
    'name': raw['name'], 'endpoint': raw['endpoint'], 'model': raw['model'],
    'additionalPrompt': raw['additionalPrompt'] ?? '',
  };

  Map<String, int> get portableModifiedAt => Map.unmodifiable(_modifiedAt);

  void _capturePortableBaseline() {
    _portableBaseline = {for (final entry in readPortableSettings().entries)
      entry.key: jsonEncode(entry.value)};
  }

  static void validatePortableSettings(String identity, Map<String, Object?> data) {
    final defaults = ComicTranslationSettings();
    try {
      final global = identity == 'global';
      if (!global) {
        final parts = jsonDecode(identity);
        if (parts is! List || parts.length != 2 ||
            parts.any((part) => part is! String || part.isEmpty) || jsonEncode(parts) != identity) {
          throw const FormatException('无效的漫画翻译设置标识');
        }
      }
      if ((global && !setEquals(data.keys.toSet(), defaults.values.keys.toSet())) ||
          (!global && data.keys.any((key) => !_comicKeys.contains(key)))) {
        throw const FormatException('无效的翻译设置字段');
      }
      for (final entry in data.entries) {
        final expected = defaults.values[entry.key];
        final value = entry.value;
        if ((expected is bool && value is! bool) ||
            (expected is String && (value is! String || value.length > 65536)) ||
            (expected is int && value is! int) ||
            (expected is double && (value is! num || !value.isFinite)) ||
            (expected is List && value is! List)) {
          throw const FormatException('无效的翻译设置值');
        }
        final bounds = <String, (num, num)>{
          'contextPages': (0, 20), 'translationPrefetchPages': (0, 30),
          'translationCachePrefetchPages': (0, 30), 'ocrMaxAnalysisSide': (320, 4096),
          'ocrDetectionThreshold': (.1, .9), 'ocrRecognitionThreshold': (.1, .9),
          'ocrUnclipRatio': (1, 3),
        }[entry.key];
        if (bounds != null && (value is! num || value < bounds.$1 || value > bounds.$2)) {
          throw const FormatException('翻译设置超出范围');
        }
      }
      if (global) {
        if (!{'none', 'local', 'openaiCompatible', 'deepl'}.contains(data['comicTranslationBackend']) ||
            !{'fast', 'balanced', 'precise', 'custom'}.contains(data['translationQuality'])) {
          throw const FormatException('无效的翻译服务或质量');
        }
        final profiles = data['comicTranslationRemoteProfiles']! as List;
        final ids = <String>{};
        if (profiles.length > 128) throw const FormatException('翻译配置数量过多');
        for (final raw in profiles) {
          if (raw is! Map || !setEquals(raw.keys.toSet(),
              {'id', 'backend', 'name', 'endpoint', 'model', 'additionalPrompt'}) ||
              raw.values.any((value) => value is! String || value.length > 65536) ||
              (raw['id'] as String).isEmpty || !ids.add(raw['id'] as String) ||
              !{'openaiCompatible', 'deepl'}.contains(raw['backend'])) {
            throw const FormatException('无效的翻译服务配置');
          }
          _validateEndpoint(raw['endpoint'] as String);
        }
        _validateEndpoint(data['comicTranslationRemoteEndpoint']! as String);
        final backend = data['comicTranslationBackend'];
        if (backend == 'openaiCompatible' || backend == 'deepl') {
          final selected = profiles.cast<Map>().where((profile) =>
            profile['id'] == data['comicTranslationRemoteProfile']).firstOrNull;
          if ((selected?['backend'] ?? 'openaiCompatible') != backend) {
            throw const FormatException('翻译服务与所选配置不一致');
          }
        }
      }
    } finally {
      defaults.dispose();
    }
  }

  static void _validateEndpoint(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasAuthority || uri.userInfo.isNotEmpty ||
        !{'http', 'https'}.contains(uri.scheme)) {
      throw const FormatException('无效的翻译服务地址');
    }
  }

  Future<void> applyPortableSettings(String identity, Map<String, Object?>? data) {
    if (identity == 'global') {
      if (data == null) throw const FormatException('全局翻译设置不可删除');
      validatePortableSettings(identity, data);
      values.addAll(data);
    } else {
      if (data != null) validatePortableSettings(identity, data);
      _detectedLanguages.remove(identity);
      if (data == null) {
        _comics.remove(identity);
      } else {
        _comics[identity] = Map<String, Object?>.of(data);
      }
    }
    return save();
  }

  Map<String, Object?> forComic(String sourceId, String comicId) =>
      Map<String, Object?>.unmodifiable({
        ...values,
        // OCR follows each comic's image quality; shared resources and budgets
        // cannot be overridden by an old per-comic settings page.
        for (final entry in (_comics[jsonEncode([sourceId, comicId])] ?? {}).entries)
          if (_comicKeys.contains(entry.key)) entry.key: entry.value,
      });

  bool hasComicOcrOverride(String sourceId, String comicId) =>
      _comics[jsonEncode([sourceId, comicId])]?.keys.any(_ocrKeys.contains) == true;

  Future<void> resetComicOcr(String sourceId, String comicId) {
    final comic = _comics[jsonEncode([sourceId, comicId])];
    if (comic == null || !comic.keys.any(_ocrKeys.contains)) return Future<void>.value();
    comic.removeWhere((key, _) => _ocrKeys.contains(key));
    return save();
  }

  Future<void> setComic(
    String sourceId,
    String comicId,
    Map<String, Object?> settings,
  ) {
    final updates = {for (final entry in settings.entries)
      if (_comicKeys.contains(entry.key)) entry.key: entry.value};
    if (updates.isEmpty) return Future<void>.value();
    final key = jsonEncode([sourceId, comicId]);
    if (updates['sourceLanguage'] == 'auto' && forComic(sourceId, comicId)['sourceLanguage'] != 'auto') {
      _detectedLanguages.remove(key);
    }
    _comics[key] = {...?_comics[key], ...updates};
    return save();
  }

  String? detectedLanguage(String sourceId, String comicId, String modelVersion) {
    final detected = _detectedLanguages[jsonEncode([sourceId, comicId])];
    return detected?.modelVersion == modelVersion ? detected?.language : null;
  }

  Future<void> rememberLanguage(String sourceId, String comicId, String language, String modelVersion) {
    final key = jsonEncode([sourceId, comicId]);
    final value = (language: language, modelVersion: modelVersion);
    if (_detectedLanguages[key] == value) return Future<void>.value();
    _detectedLanguages[key] = value;
    return _save(notify: false);
  }

  Future<void> save() => _save();

  Future<void> _save({bool notify = true}) {
    if (notify) {
      final now = DateTime.now().toUtc().microsecondsSinceEpoch;
      final current = readPortableSettings();
      for (final key in {...current.keys, ..._portableBaseline.keys}) {
        if (jsonEncode(current[key]) != _portableBaseline[key]) _modifiedAt[key] = now;
      }
      _capturePortableBaseline();
    }
    final payload = jsonEncode({'settings': values, 'comics': _comics,
      'modifiedAt': _modifiedAt,
      'credentialServices': _credentialServices,
      'detectedLanguages': {for (final entry in _detectedLanguages.entries) entry.key: {
        'language': entry.value.language, 'modelVersion': entry.value.modelVersion,
      }},
    });
    final task = _tail.then((_) async {
      final temporary = File('${_file.path}.tmp');
      await temporary.writeAsString(payload, flush: true);
      await temporary.rename(_file.path);
    });
    _tail = task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    if (notify) notifyListeners();
    return task;
  }

  Future<void> flush() => _tail;
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Non-secret preferences. API keys belong exclusively to the secrets store.
final class ComicTranslationSettings extends ChangeNotifier {
  ComicTranslationSettings();

  static final instance = ComicTranslationSettings();
  final Map<String, Object?> values = {
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
    'translateSoundEffects': false,
    'useCleanOverlay': true,
    'enabled': false,
  };
  final Map<String, Map<String, Object?>> _comics = {};
  final Map<String, ({String language, String modelVersion})> _detectedLanguages = {};
  late File _file;
  Future<void> _tail = Future<void>.value();

  Future<void> init(String directory) async {
    _file = File('$directory/comic_translation_settings.json');
    final temporary = File('${_file.path}.tmp');
    if (!await _file.exists() && await temporary.exists()) {
      await temporary.rename(_file.path);
    }
    if (!await _file.exists()) return;
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
  }

  Map<String, Object?> forComic(String sourceId, String comicId) =>
      Map<String, Object?>.unmodifiable({
        ...values,
        ...?_comics[jsonEncode([sourceId, comicId])],
      });

  Future<void> setComic(
    String sourceId,
    String comicId,
    Map<String, Object?> settings,
  ) {
    final key = jsonEncode([sourceId, comicId]);
    if (settings['sourceLanguage'] == 'auto' && forComic(sourceId, comicId)['sourceLanguage'] != 'auto') {
      _detectedLanguages.remove(key);
    }
    _comics[key] = {...?_comics[key], ...settings};
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
    final payload = jsonEncode({'settings': values, 'comics': _comics,
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

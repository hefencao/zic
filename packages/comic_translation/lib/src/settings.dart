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
    _comics[key] = {...?_comics[key], ...settings};
    return save();
  }

  Future<void> save() {
    final payload = jsonEncode({'settings': values, 'comics': _comics});
    final task = _tail.then((_) async {
      final temporary = File('${_file.path}.tmp');
      await temporary.writeAsString(payload, flush: true);
      await temporary.rename(_file.path);
    });
    _tail = task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    notifyListeners();
    return task;
  }

  Future<void> flush() => _tail;
}

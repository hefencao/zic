import 'dart:io';

import 'package:comic_translation/comic_translation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('comic policy is source-scoped, merges toggles and persists separately from keys', () async {
    final directory = await Directory.systemTemp.createTemp('zic_translation_settings_');
    try {
      final settings = ComicTranslationSettings();
      await settings.init(directory.path);
      settings.values['targetLanguage'] = 'en';
      await settings.setComic('source-a', 'comic', {'targetLanguage': 'zh-TW'});
      await settings.setComic('source-a', 'comic', {'enabled': true});
      expect(settings.forComic('source-a', 'comic')['targetLanguage'], 'zh-TW');
      expect(settings.forComic('source-b', 'comic')['targetLanguage'], 'en');
      expect(settings.forComic('source-b', 'comic')['enabled'], isFalse);
      final secrets = ComicTranslationSecrets.instance;
      await secrets.init(directory.path);
      await secrets.setApiKey('openai', 'private-openai-key');
      await secrets.setApiKey('deepl', 'private-deepl-key');
      final restored = ComicTranslationSettings();
      await restored.init(directory.path);
      expect(restored.forComic('source-a', 'comic')['enabled'], isTrue);
      expect(restored.forComic('source-a', 'comic')['targetLanguage'], 'zh-TW');
      expect(restored.forComic('source-b', 'comic')['targetLanguage'], 'en');
      final plain = await File('${directory.path}/comic_translation_settings.json').readAsString();
      expect(plain, isNot(contains('private-')));
      await secrets.init(directory.path);
      expect(secrets.apiKeyFor('openai'), 'private-openai-key');
      expect(secrets.apiKeyFor('deepl'), 'private-deepl-key');
      await secrets.removeProfile('openai');
      expect(secrets.hasApiKey('openai'), isFalse);
      expect(secrets.apiKeyFor('deepl'), 'private-deepl-key');
      settings.dispose();
      restored.dispose();
    } finally {
      await directory.delete(recursive: true);
    }
  });
}

import 'dart:convert';
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
      await settings.setComic('source-a', 'comic', {'showIndicator': false});
      await settings.setComic('source-a', 'comic', {'sourceLanguage': 'ja'});
      await settings.setComic('source-a', 'korean', {'sourceLanguage': 'ko'});
      await settings.setComic('source-a', 'korean', {'indicatorOnlyWhileProcessing': true});
      var notifications = 0;
      settings.addListener(() { notifications++; });
      await settings.rememberLanguage('source-a', 'automatic', 'ko', 'ocr-v1');
      expect(notifications, 0, reason: 'learning a language must not rebuild an active session');
      expect(settings.forComic('source-a', 'comic')['targetLanguage'], 'zh-TW');
      expect(settings.forComic('source-b', 'comic')['targetLanguage'], 'en');
      expect(settings.forComic('source-b', 'comic')['enabled'], isFalse);
      final secrets = ComicTranslationSecrets.instance;
      await secrets.init(directory.path);
      await secrets.setApiKey('openai', 'private-openai-key');
      await secrets.setApiKey('deepl', 'private-deepl-key');
      final settingsFile = File('${directory.path}/comic_translation_settings.json');
      final saved = jsonDecode(await settingsFile.readAsString()) as Map;
      (saved['settings'] as Map).remove('indicatorOnlyWhileProcessing');
      await settingsFile.writeAsString(jsonEncode(saved));
      final restored = ComicTranslationSettings();
      await restored.init(directory.path);
      expect(restored.forComic('source-a', 'comic')['enabled'], isTrue);
      expect(restored.forComic('source-a', 'comic')['showIndicator'], isFalse);
      expect(restored.forComic('source-b', 'comic')['showIndicator'], isTrue);
      expect(restored.forComic('source-a', 'comic')['indicatorOnlyWhileProcessing'], isFalse);
      expect(restored.forComic('source-b', 'comic')['indicatorOnlyWhileProcessing'], isFalse);
      expect(restored.forComic('source-a', 'korean')['indicatorOnlyWhileProcessing'], isTrue);
      expect(restored.forComic('source-a', 'comic')['targetLanguage'], 'zh-TW');
      expect(restored.forComic('source-b', 'comic')['targetLanguage'], 'en');
      expect(restored.forComic('source-a', 'comic')['sourceLanguage'], 'ja');
      expect(restored.forComic('source-a', 'korean')['sourceLanguage'], 'ko');
      expect(restored.values['sourceLanguage'], 'auto');
      expect(restored.detectedLanguage('source-a', 'automatic', 'ocr-v1'), 'ko');
      expect(restored.detectedLanguage('source-b', 'automatic', 'ocr-v1'), isNull);
      expect(restored.detectedLanguage('source-a', 'automatic', 'ocr-v2'), isNull);
      await restored.setComic('source-a', 'automatic', {'sourceLanguage': 'ja'});
      await restored.setComic('source-a', 'automatic', {'sourceLanguage': 'auto'});
      expect(restored.detectedLanguage('source-a', 'automatic', 'ocr-v1'), isNull);
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

  test('quality presets and custom OCR overrides survive restart per comic', () async {
    final directory = await Directory.systemTemp.createTemp('zic-translation-settings-');
    try {
      final settings = ComicTranslationSettings();
      await settings.init(directory.path);
      settings.values.addAll({
        ...ComicTranslationQuality.precise.settings,
        'translationQuality': 'precise',
        'comicTranslationBackend': 'openaiCompatible',
        'comicTranslationRemoteModel': 'configured-model',
      });
      await settings.setComic('source', 'comic', {
        ...ComicTranslationQuality.fast.settings,
        'translationQuality': 'custom',
        'ocrRecognitionThreshold': .55,
      });
      final restored = ComicTranslationSettings();
      await restored.init(directory.path);
      final comic = restored.forComic('source', 'comic');
      expect(ComicOcrParameters.fromSettings(comic).maxAnalysisSide, 1024);
      expect(ComicOcrParameters.fromSettings(comic).recognitionThreshold, .55);
      expect(comic['translationQuality'], 'custom');
      expect(comic['contextPages'], 0);
      expect(comic['translationPrefetchPages'], 2);
      expect(comic['translationCachePrefetchPages'], 4);
      final other = restored.forComic('source', 'other');
      expect(ComicOcrParameters.fromSettings(other).maxAnalysisSide, 2240);
      expect(other['contextPages'], 4);
      expect(other['translationQuality'], 'precise');
      expect(other['comicTranslationBackend'], 'openaiCompatible');
      expect(other['comicTranslationRemoteModel'], 'configured-model');
      expect(comic['comicTranslationRemoteModel'], 'configured-model');
      settings.dispose();
      restored.dispose();
    } finally {
      await directory.delete(recursive: true);
    }
  });
}

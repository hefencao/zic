import 'dart:convert';
import 'dart:io';

import 'package:comic_translation/comic_translation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy service profiles export only supported non-secret fields', () async {
    final directory = await Directory.systemTemp.createTemp('zic-translation-legacy-profile-');
    try {
      await File('${directory.path}/comic_translation_settings.json').writeAsString(jsonEncode({
        'settings': {'comicTranslationRemoteProfiles': [
          {'id': 'old', 'name': 'Old', 'endpoint': 'https://example.test/api',
            'model': 'old-model', 'apiKey': 'must-stay-local'},
        ]},
      }));
      final settings = ComicTranslationSettings();
      await settings.init(directory.path);
      final data = settings.readPortableSettings()['global']!;
      ComicTranslationSettings.validatePortableSettings('global', data);
      expect(jsonEncode(data), isNot(contains('must-stay-local')));
      expect((data['comicTranslationRemoteProfiles'] as List).single, {
        'id': 'old', 'name': 'Old', 'endpoint': 'https://example.test/api', 'model': 'old-model',
        'backend': 'openaiCompatible', 'additionalPrompt': '',
      });
      settings.dispose();
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('portable service configuration cannot rebind existing device credentials', () async {
    final directory = await Directory.systemTemp.createTemp('zic-translation-credential-binding-');
    try {
      final settings = ComicTranslationSettings();
      await settings.init(directory.path);
      const original = 'https://api.openai.com/v1/chat/completions';
      const restored = 'https://other.example.test/v1/chat/completions';
      expect(settings.permitsCredentialService('default', 'openaiCompatible', original), isTrue);
      final portable = settings.readPortableSettings()['global']!;
      await settings.applyPortableSettings('global', {
        ...portable, 'comicTranslationRemoteEndpoint': restored,
      });
      expect(settings.permitsCredentialService('default', 'openaiCompatible', restored), isFalse);
      await settings.setComic('source', 'comic', {'enabled': true});
      final reopened = ComicTranslationSettings();
      await reopened.init(directory.path);
      expect(reopened.permitsCredentialService('default', 'openaiCompatible', restored), isFalse);
      expect(reopened.permitsCredentialService('default', 'openaiCompatible', original), isTrue);
      expect(jsonEncode(reopened.readPortableSettings()), isNot(contains('credentialServices')));
      reopened.approveCredentialService('default', 'openaiCompatible', restored);
      await reopened.save();
      expect(reopened.permitsCredentialService('default', 'openaiCompatible', restored), isTrue);
      settings.dispose();
      reopened.dispose();
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('comic policy is source-scoped, merges toggles and persists separately from keys', () async {
    final directory = await Directory.systemTemp.createTemp('zic_translation_settings_');
    try {
      final settings = ComicTranslationSettings();
      await settings.init(directory.path);
      expect(settings.values['indicatorOnlyWhileProcessing'], isTrue);
      expect(settings.forComic('source-b', 'comic')['indicatorOnlyWhileProcessing'], isTrue);
      settings.values['indicatorOnlyWhileProcessing'] = false;
      settings.values['targetLanguage'] = 'en';
      await settings.setComic('source-a', 'comic', {'enabled': true});
      await settings.setComic('source-a', 'comic', {'showIndicator': false});
      await settings.setComic('source-a', 'comic', {'sourceLanguage': 'ja'});
      await settings.setComic('source-a', 'korean', {'sourceLanguage': 'ko'});
      await settings.setComic('source-a', 'korean', {'indicatorOnlyWhileProcessing': true});
      var notifications = 0;
      settings.addListener(() { notifications++; });
      await settings.rememberLanguage('source-a', 'automatic', 'ko', 'ocr-v1');
      expect(notifications, 0, reason: 'learning a language must not rebuild an active session');
      expect(settings.forComic('source-a', 'comic')['targetLanguage'], 'en');
      expect(settings.forComic('source-b', 'comic')['targetLanguage'], 'en');
      expect(settings.forComic('source-b', 'comic')['enabled'], isFalse);
      final secrets = ComicTranslationSecrets.instance;
      await secrets.init(directory.path);
      await secrets.setApiKey('openai', 'private-openai-key');
      await secrets.setApiKey('deepl', 'private-deepl-key');
      final settingsFile = File('${directory.path}/comic_translation_settings.json');
      final savedPreference = ComicTranslationSettings();
      await savedPreference.init(directory.path);
      expect(savedPreference.values['indicatorOnlyWhileProcessing'], isFalse,
        reason: 'the new default must preserve an explicitly saved always-visible preference');
      savedPreference.dispose();
      final saved = jsonDecode(await settingsFile.readAsString()) as Map;
      (saved['settings'] as Map).remove('indicatorOnlyWhileProcessing');
      await settingsFile.writeAsString(jsonEncode(saved));
      final restored = ComicTranslationSettings();
      await restored.init(directory.path);
      expect(restored.forComic('source-a', 'comic')['enabled'], isTrue);
      expect(restored.forComic('source-a', 'comic')['showIndicator'], isFalse);
      expect(restored.forComic('source-b', 'comic')['showIndicator'], isTrue);
      expect(restored.forComic('source-a', 'comic')['indicatorOnlyWhileProcessing'], isTrue);
      expect(restored.forComic('source-b', 'comic')['indicatorOnlyWhileProcessing'], isTrue);
      expect(restored.forComic('source-a', 'korean')['indicatorOnlyWhileProcessing'], isTrue);
      expect(restored.forComic('source-a', 'comic')['targetLanguage'], 'en');
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

  test('comic OCR overrides persist and reset without overriding shared resources', () async {
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
      await settings.setComic('source', 'comic', {'sourceLanguage': 'ko',
        'translateSoundEffects': true, 'useCleanOverlay': false});
      final file = File('${directory.path}/comic_translation_settings.json');
      final legacy = jsonDecode(await file.readAsString()) as Map;
      final oldComic = (legacy['comics'] as Map)[jsonEncode(['source', 'comic'])] as Map;
      oldComic.addAll(<String, dynamic>{...ComicTranslationQuality.fast.settings,
        'translationQuality': 'custom', 'ocrRecognitionThreshold': .55,
        'targetLanguage': 'en', 'comicTranslationBackend': 'none'});
      await file.writeAsString(jsonEncode(legacy));
      final restored = ComicTranslationSettings();
      await restored.init(directory.path);
      final comic = restored.forComic('source', 'comic');
      expect(ComicOcrParameters.fromSettings(comic).maxAnalysisSide, 1024);
      expect(ComicOcrParameters.fromSettings(comic).recognitionThreshold, .55);
      expect(restored.hasComicOcrOverride('source', 'comic'), isTrue);
      expect(comic['translationQuality'], 'precise');
      expect(comic['contextPages'], 4);
      expect(comic['translationPrefetchPages'], 6);
      expect(comic['translationCachePrefetchPages'], 6);
      expect(comic['targetLanguage'], 'zh-CN');
      expect(comic['comicTranslationBackend'], 'openaiCompatible');
      expect(comic['sourceLanguage'], 'ko');
      expect(comic['translateSoundEffects'], isTrue);
      expect(comic['useCleanOverlay'], isFalse);
      await restored.setComic('source', 'other', {
        ...ComicTranslationQuality.fast.settings, 'translationQuality': 'fast',
        'targetLanguage': 'en', 'comicTranslationBackend': 'none',
      });
      final other = restored.forComic('source', 'other');
      expect(ComicOcrParameters.fromSettings(other).maxAnalysisSide, 1024);
      expect(other['contextPages'], 4);
      expect(other['targetLanguage'], 'zh-CN');
      expect(other['sourceLanguage'], 'auto');
      expect(other['translationQuality'], 'precise');
      expect(other['comicTranslationBackend'], 'openaiCompatible');
      expect(other['comicTranslationRemoteModel'], 'configured-model');
      expect(comic['comicTranslationRemoteModel'], 'configured-model');
      expect(restored.forComic('other-source', 'comic')['ocrMaxAnalysisSide'], 2240);
      await restored.resetComicOcr('source', 'comic');
      expect(restored.hasComicOcrOverride('source', 'comic'), isFalse);
      expect(ComicOcrParameters.fromSettings(restored.forComic('source', 'comic')).maxAnalysisSide, 2240);
      restored.values['ocrMaxAnalysisSide'] = 1600;
      await restored.save();
      final reloaded = ComicTranslationSettings();
      await reloaded.init(directory.path);
      final inherited = reloaded.forComic('source', 'comic');
      expect(ComicOcrParameters.fromSettings(inherited).maxAnalysisSide, 1600);
      expect(ComicOcrParameters.fromSettings(inherited).recognitionThreshold, .35);
      expect(reloaded.hasComicOcrOverride('source', 'comic'), isFalse);
      expect(inherited['sourceLanguage'], 'ko');
      expect(inherited['translateSoundEffects'], isTrue);
      expect(inherited['useCleanOverlay'], isFalse);
      expect(inherited['contextPages'], 4);
      expect(inherited['targetLanguage'], 'zh-CN');
      expect(reloaded.forComic('source', 'other')['ocrMaxAnalysisSide'], 1024);
      reloaded.dispose();
      settings.dispose();
      restored.dispose();
    } finally {
      await directory.delete(recursive: true);
    }
  });
}

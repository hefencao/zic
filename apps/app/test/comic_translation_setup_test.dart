import 'dart:convert';
import 'dart:io';

import 'package:comic_translation/comic_translation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/comic_translation_service_form.dart';
import 'package:zic/comic_translation_settings_entry.dart';
import 'package:zic/comic_translation_settings_screen.dart';
import 'package:zic/comic_translation_setup_screen.dart';
import 'package:zic/startup_platform.dart';
import 'package:zic/translation_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;
  final settings = ComicTranslationSettings.instance;
  final secrets = ComicTranslationSecrets.instance;
  late Map<String, Object?> defaults;

  setUpAll(() async {
    support = await Directory.systemTemp.createTemp('zic-translation-setup-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(startupPlatformChannel, (call) async =>
          call.method == 'applicationSupportPath' ? support.path : null);
    // Sparse files exercise only the installed-model contract, never OCR inference.
    final bundle = ComicOcrModelManager.bundle;
    final models = Directory('${support.path}/zic/translation/comic_translation/models/${bundle.id}');
    await models.create(recursive: true);
    for (final file in bundle.files) {
      final handle = await File('${models.path}/${file.name}').open(mode: FileMode.write);
      await handle.truncate(file.bytes);
      await handle.close();
    }
    await File('${models.path}/installation.json').writeAsString(jsonEncode({
      'id': bundle.id, 'version': bundle.version,
      'files': {for (final file in bundle.files) file.name: file.sha256},
    }));
    await initializeComicTranslation();
    defaults = Map.of(settings.values);
  });
  tearDownAll(() async {
    await settings.flush();
    await ComicTranslationStore.instance.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(startupPlatformChannel, null);
    await support.delete(recursive: true);
  });

  testWidgets('first-use completion, cancellation and existing configuration keep their boundaries', (tester) async {
    settings.values.addAll({...defaults, 'translationPrefetchPages': 6, 'showIndicator': false,
      'targetLanguage': 'zh-TW'});
    await tester.runAsync(() => settings.setComic('source', 'comic', {'sourceLanguage': 'ko',
      'ocrMaxAnalysisSide': 2240, 'comicTranslationSetupCompleted': true}));
    var enabled = false;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(body: Column(children: [
      TextButton(onPressed: () => openComicTranslationSettings(context), child: const Text('settings-entry')),
      TextButton(onPressed: () async {
        if (await ensureComicTranslationSetup(context)) enabled = true;
      }, child: const Text('enable-entry')),
    ])))));
    Future<void> settle() async {
      for (var i = 0; i < 100; i++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
        if (find.byWidgetPredicate((widget) => widget is CircularProgressIndicator ||
            widget is LinearProgressIndicator && widget.value == null).evaluate().isEmpty) {
          break;
        }
      }
      await tester.pumpAndSettle();
    }
    Future<void> tap(String text) async {
      await tester.runAsync(() => tester.tap(find.text(text)));
      await settle();
    }
    Future<void> back() async {
      await tester.pageBack();
      await settle();
    }
    Finder field(String label) => find.byWidgetPredicate((widget) =>
      widget is TextField && widget.decoration?.labelText == label);

    await tap('enable-entry');
    expect(find.byKey(comicTranslationSetupKey), findsOneWidget);
    expect(find.byKey(comicTranslationSettingsKey), findsNothing);
    await tap('稍后设置');
    expect(enabled, isFalse, reason: 'cancelling first use must not enable comic translation');
    expect(settings.values['comicTranslationSetupCompleted'], isFalse);

    await tap('settings-entry');
    await tap('下一步');
    expect(find.text('文字识别已就绪'), findsOneWidget);
    await tap('下一步');
    await tester.enterText(field('API 地址'), 'invalid');
    await tester.enterText(field('模型名称'), 'setup-model');
    await tester.enterText(field('API 密钥'), 'setup-key');
    await tester.runAsync(() => tester.tap(find.text('完成设置')));
    await settle();
    expect(find.byKey(comicTranslationSetupKey), findsOneWidget);
    expect(settings.values['comicTranslationBackend'], 'none');
    expect(secrets.hasApiKey('default'), isFalse, reason: 'validation failure cannot persist credentials');
    await back();
    expect(settings.values['comicTranslationSetupCompleted'], isFalse);
    expect(settings.values['comicTranslationRemoteProfiles'], isEmpty);
    expect(secrets.hasApiKey('default'), isFalse, reason: 'leaving setup discards its draft');
    expect(ComicOcrModelManager.instance.installed, isTrue, reason: 'a shared download is retained');

    await tap('enable-entry');
    await tap('下一步');
    await tap('下一步');
    await tester.enterText(field('API 地址'), 'https://example.invalid/v1/chat/completions');
    await tester.enterText(field('模型名称'), 'setup-model');
    await tester.enterText(field('API 密钥'), 'setup-key');
    await tester.runAsync(() => tester.tap(find.text('完成设置')));
    await settle();
    expect(find.byKey(comicTranslationSetupKey), findsNothing);
    expect(enabled, isTrue);
    expect(settings.values['comicTranslationSetupCompleted'], isTrue);
    expect(secrets.apiKeyFor('default'), 'setup-key');
    expect(settings.values['enabled'], isFalse, reason: 'setup does not change default reader enablement');
    expect(settings.values['translationPrefetchPages'], 6);
    expect(settings.values['showIndicator'], isFalse);
    expect(settings.values['targetLanguage'], 'zh-TW');
    expect(settings.forComic('source', 'comic')['sourceLanguage'], 'ko');
    expect(settings.forComic('source', 'comic')['ocrMaxAnalysisSide'], 2240);
    final reloaded = ComicTranslationSettings();
    await tester.runAsync(() => reloaded.init('${support.path}/zic/translation'));
    expect(reloaded.values['comicTranslationSetupCompleted'], isTrue, reason: 'completion survives restart');
    await tester.runAsync(() => settings.setComic('source', 'comic', {'comicTranslationSetupCompleted': false}));
    expect(settings.forComic('source', 'comic')['comicTranslationSetupCompleted'], isTrue,
      reason: 'setup completion is global, never per comic');

    await tap('settings-entry');
    expect(find.byKey(comicTranslationSettingsKey), findsOneWidget);
    expect(find.byKey(comicTranslationSetupKey), findsNothing);
    await tester.enterText(field('模型名称'), 'unsaved-setting');
    await tester.tap(find.byTooltip('重新运行初始设置'));
    await settle();
    expect(find.byKey(comicTranslationSetupKey), findsOneWidget);
    await tap('稍后设置');
    expect(tester.widget<TextField>(field('模型名称')).controller!.text, 'unsaved-setting',
      reason: 'cancelled explicit setup must leave an existing settings draft alone');
    expect(settings.values['comicTranslationSetupCompleted'], isTrue);
    await back();

    settings.values.addAll({'comicTranslationSetupCompleted': false,
      'comicTranslationRemoteProfiles': <Object?>[], 'comicTranslationRemoteProfile': 'default',
      'comicTranslationRemoteEndpoint': 'https://example.invalid/v1/chat/completions',
      'comicTranslationRemoteModel': 'legacy-model'});
    await tap('settings-entry');
    expect(find.byKey(comicTranslationSetupKey), findsNothing,
      reason: 'an existing usable legacy configuration skips first use without a new completion flag');
    expect(tester.widget<TextField>(field('模型名称')).controller!.text, 'legacy-model');
    await back();

    settings.values.addAll({...defaults, 'comicTranslationSetupCompleted': false});
    await tap('settings-entry');
    await tap('手动设置');
    expect(find.byKey(comicTranslationSettingsKey), findsOneWidget);
    expect(settings.values['comicTranslationSetupCompleted'], isFalse,
      reason: 'choosing manual setup alone is not completion');
    await back();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('provider/profile changes stage credentials until explicit save', () async {
    settings.values.addAll({...defaults, 'comicTranslationBackend': 'openaiCompatible',
      'comicTranslationRemoteModel': 'legacy-model'});
    await secrets.setApiKey('default', 'original-key');
    final draft = ComicTranslationServiceDraft(settings.values);
    draft.apiKey.text = 'replacement-key';
    draft.selectBackend('deepl');
    draft.apiKey.text = 'deepl-key';
    draft.selectBackend('openaiCompatible');
    expect(draft.apiKey.text, 'replacement-key');
    expect(secrets.apiKeyFor('default'), 'original-key');
    draft.addProfile();
    final added = draft.profileId;
    draft.apiKey.text = 'new-profile-key';
    draft.selectProfile('default');
    draft.clearKey();
    expect(secrets.apiKeyFor('default'), 'original-key');
    draft.selectProfile(added);
    draft.deleteProfile();
    expect(secrets.hasApiKey(added), isFalse);
    await draft.apply();
    expect(secrets.hasApiKey('default'), isFalse);
    expect(secrets.hasApiKey(added), isFalse, reason: 'a deleted draft profile cannot leak a credential');
    expect(settings.values['comicTranslationBackend'], 'openaiCompatible');
    draft.apiKey.text = 'saved-before-exit';
    final saving = draft.apply();
    draft.dispose();
    await saving;
    expect(secrets.apiKeyFor('default'), 'saved-before-exit',
      reason: 'an explicit save may finish after its editing page is disposed');
  });
}

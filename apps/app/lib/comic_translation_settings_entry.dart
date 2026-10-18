import 'package:comic_translation/comic_translation.dart';
import 'package:flutter/material.dart';

import 'comic_translation_service_form.dart';
import 'comic_translation_settings_screen.dart';
import 'comic_translation_setup_screen.dart';
import 'translation_runtime.dart';

/// Only explicit App commands open setup; media/session owners never navigate.
Future<bool> ensureComicTranslationSetup(BuildContext context, {bool openSettings = false}) async {
  try {
    await initializeComicTranslation();
  } on Object catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('无法加载翻译设置：$error')));
    }
    return false;
  }
  if (!context.mounted) return false;
  var manual = false;
  if (ComicTranslationSettings.instance.values['comicTranslationSetupCompleted'] != true &&
      !hasComicTranslationServiceConfiguration()) {
    final result = await Navigator.of(context).push<ComicTranslationSetupResult>(MaterialPageRoute(
      builder: (_) => const ComicTranslationSetupScreen()));
    if (result == null || !context.mounted) return false;
    manual = result == ComicTranslationSetupResult.manual;
  }
  if (openSettings || manual) {
    if (!context.mounted) return false;
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => const ComicTranslationSettingsScreen()));
  }
  return ComicTranslationSettings.instance.values['comicTranslationSetupCompleted'] == true ||
      hasComicTranslationServiceConfiguration();
}

Future<void> openComicTranslationSettings(BuildContext context) async {
  await ensureComicTranslationSetup(context, openSettings: true);
}

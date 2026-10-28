import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:comic_translation/comic_translation.dart';
import 'package:downloads/downloads.dart';
import 'package:domain/domain.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_bridge/network_bridge.dart';
import 'package:sessions/sessions.dart';
import 'package:zic/app_preferences.dart';
import 'package:zic/extension_repositories.dart';
import 'package:zic/library_backup.dart';
import 'package:zic/library_backup_import_screen.dart';
import 'package:zic/library_data_scope.dart';
import 'package:zic/library_sync.dart';
import 'package:zic/library_sync_store.dart';
import 'package:zic/portable_settings.dart';
import 'package:zic/webdav_sync.dart';

void main() {
  test('selected backup data excludes other owners and preserves their deletion clocks', () async {
    final a = await _Fixture.create();
    final b = await _Fixture.create();
    a.preferences.setThemeMode(ThemeMode.dark);
    a.translation.values['targetLanguage'] = 'en';
    await a.translation.save();
    final app = await a.controller.exportRecords(sections: {LibraryDataSection.appSettings});
    expect(app.keys.every((key) => libraryDataSection(key) == LibraryDataSection.appSettings), isTrue);
    expect(a.translationReads, 0);
    expect(a.sourceReads, 0);
    await b.controller.importRecords(app, sections: {LibraryDataSection.appSettings});
    expect(b.preferences.themeMode, ThemeMode.dark);
    expect(b.translation.values['targetLanguage'], 'zh-CN');
    expect(b.translationReads, 0);
    expect(b.sourceReads, 0);
    expect(b.libraryApplications, 0, reason: 'settings-only restore must not reload the library');
    final all = await a.controller.exportRecords();
    final versions = jsonEncode(a.files['state.json']!['versions']);
    await a.controller.exportRecords(sections: {LibraryDataSection.appSettings});
    expect(jsonEncode(a.files['state.json']!['versions']), versions,
      reason: 'omitted records are not captured as new tombstones');
    await b.controller.importRecords(all, sections: {LibraryDataSection.translation});
    expect(b.translation.values['targetLanguage'], 'en');
    expect(b.sourceReads, 0);
    expect(b.plugin.updates, 0);
  });

  for (final access in ['saf', 'direct']) {
    test('restoring $access keeps device paths and persists the setup guide', () async {
      final a = await _Fixture.create();
      final b = await _Fixture.create();
      Map<String, Object?>? saved;
      await b.preferences.attach(read: () async => null, write: (data) async => saved = data);
      a.preferences.setChapterDownloadDirectoryOverride(access == 'saf'
        ? 'saf://content://provider/tree/private' : '/private/downloads');
      await b.controller.importRecords(await a.controller.exportRecords());
      expect(b.preferences.downloadAccessPreference, access);
      expect(b.preferences.downloadDirectorySetupRequired, isTrue);
      expect(b.preferences.chapterDownloadDirectoryOverride, isNull);
      expect(b.controller.message, contains('配置下载目录与访问授权'));
      final records = await b.controller.exportRecords();
      expect(records['setting:storage\u0000download']!.data, {'access': access});
      expect(utf8.decode(encodeLibrarySync(records, compress: false)), isNot(contains('/private')));
      final restarted = AppPreferencesController();
      await restarted.attach(read: () async => saved, write: (_) async {});
      expect(restarted.downloadAccessPreference, access);
      expect(restarted.downloadDirectorySetupRequired, isTrue);
      restarted.setChapterDownloadDirectoryOverride('saf://content://provider/tree/new');
      restarted.confirmDownloadDirectorySetup(access: access);
      expect(restarted.downloadDirectorySetupRequired, isFalse);
      restarted.dispose();
    });
  }

  TestWidgetsFlutterBinding.ensureInitialized();

  test('portable settings round trip keeps paths, budgets, credentials and learned state local', () async {
    final a = await _Fixture.create();
    final b = await _Fixture.create();
    a.preferences.setThemeMode(ThemeMode.dark);
    a.preferences.setShelfPluginFilterExpanded(true);
    a.preferences.setSourceAdaptiveWebtoonConfidence('source', .8);
    a.preferences.setSourceTrustConflictingHistoricalCarriers('source', false);
    a.preferences.setChapterDownloadDirectoryOverride('/private/a');
    a.preferences.setCacheLimitMb(8192);
    a.translation.values['targetLanguage'] = 'en';
    a.translation.values['comicTranslationRemoteProfiles'] = [const ComicTranslationRemoteProfile(
      id: 'custom', name: 'Custom', endpoint: 'https://example.test/translate',
      model: 'model', additionalPrompt: 'Keep the balloons short').toJson()];
    await a.translation.save();
    await a.translation.setComic('source', 'comic', {'enabled': true,
      'sourceLanguage': 'ja', 'ocrMaxAnalysisSide': 2240, 'showIndicator': false});
    await a.translation.rememberLanguage('source', 'detected', 'ko', 'ocr-v1');
    a.policy = const WholeComicQueuePolicy(concurrency: 3,
      network: WholeComicNetworkPolicy.unmetered, power: WholeComicPowerPolicy.charging);
    a.plugin.value = 'second';
    await a.owner.rememberPluginChange(a.plugin.sourceId, a.plugin.setting, 'second');
    await a.store.saveSourcePreference(ComicSourcePreference(sourceId: 'source',
      enabled: false, sortOrder: 3, updatedAt: DateTime.utc(2026)));
    final records = await a.controller.exportRecords();
    final bytes = const MetadataGzipCodec().encode(encodeLibrarySync(records, compress: false));
    final imported = decodeImportedLibraryBackup(bytes);
    final text = utf8.decode(encodeLibrarySync(imported, compress: false));
    expect(text, isNot(contains('private-login-token')));
    expect(text, isNot(contains('/private/a')));
    expect(text, isNot(contains('detectedLanguages')));
    expect(text, isNot(contains('cacheLimitMb')));
    await b.controller.importRecords(imported);
    expect(b.preferences.themeMode, ThemeMode.dark);
    expect(b.preferences.shelfPluginFilterExpanded, isTrue);
    expect(b.preferences.readPortableSettings()['sourceAdaptiveWebtoonConfidences'], {'source': .8});
    expect(b.preferences.trustConflictingHistoricalCarriersForSource('source'), isFalse);
    expect(b.preferences.chapterDownloadDirectoryOverride, isNull);
    expect(b.preferences.cacheLimitMb, isNot(8192));
    expect(b.translation.values['targetLanguage'], 'en');
    expect(b.translation.forComic('source', 'comic')['sourceLanguage'], 'ja');
    expect(b.translation.forComic('source', 'comic')['ocrMaxAnalysisSide'], 2240);
    expect(b.translation.forComic('source', 'comic')['showIndicator'], isFalse);
    expect(b.translation.detectedLanguage('source', 'detected', 'ocr-v1'), isNull);
    expect(b.plugin.value, 'second');
    expect(b.plugin.actions, 0);
    expect(b.policy.toJson(), a.policy.toJson());
    expect((await b.store.listSourcePreferences()).single.enabled, isFalse);
    expect(b.controller.lastResult, isNull, reason: 'local import does not claim a cloud sync');
    final restart = ComicTranslationSettings();
    await restart.init(b.directory.path);
    expect(restart.forComic('source', 'comic')['sourceLanguage'], 'ja');
    restart.dispose();
  });

  test('unavailable plugins retain pending settings and restore through the declared source interface', () async {
    final a = await _Fixture.create();
    final b = await _Fixture.create();
    a.plugin.value = 'second';
    b.includePlugin = false;
    final records = await a.controller.exportRecords();
    await b.controller.importRecords(records);
    expect(b.owner.pendingPlugins, 1);
    expect(b.plugin.value, 'first');
    b.includePlugin = true;
    await b.owner.restorePluginSettings(b.plugin);
    expect(b.plugin.value, 'second');
    await b.owner.read();
    expect(b.owner.pendingPlugins, 0);
    expect(b.plugin.actions, 0);
  });

  test('repositories merge independently, keep disabled/deleted choices and survive restart', () async {
    final a = await _Fixture.create();
    final b = await _Fixture.create();
    final first = ExtensionRepository(format: ExternalComicPluginFormat.veneraJavaScript,
      index: Uri.https('first.example', '/index.json'));
    final second = ExtensionRepository(format: ExternalComicPluginFormat.mihonExtension,
      index: Uri.https('second.example', '/index.pb'), enabled: false, name: '备用仓库');
    final local = ExtensionRepository(format: ExternalComicPluginFormat.veneraJavaScript,
      index: Uri.https('local.example', '/index.json'));
    Map<String, Object?>? persisted;
    await b.preferences.attach(read: () async => null, write: (value) async => persisted = value);
    a.preferences.setExtensionRepository(first);
    a.preferences.setExtensionRepository(second);
    b.preferences.setExtensionRepository(local);
    await b.controller.importRecords(await a.controller.exportRecords());
    expect(b.preferences.extensionRepositories.map((item) => item.identity),
      unorderedEquals([first.identity, second.identity, local.identity]));
    expect(b.preferences.extensionRepositories.singleWhere((item) => item.identity == second.identity).enabled, isFalse);
    expect(b.preferences.extensionRepositories.singleWhere((item) => item.identity == second.identity).name, '备用仓库');
    a.preferences.removeExtensionRepository(first);
    await b.controller.importRecords(await a.controller.exportRecords());
    expect(b.preferences.extensionRepositories.map((item) => item.identity),
      unorderedEquals([second.identity, local.identity]));
    final restart = AppPreferencesController();
    addTearDown(restart.dispose);
    await restart.attach(read: () async => persisted, write: (_) async {});
    expect(restart.extensionRepositoryRecords.containsKey(first.identity), isTrue);
    expect(restart.extensionRepositoryRecords[first.identity], isNull);
    expect(restart.extensionRepositories.singleWhere((item) => item.identity == second.identity).enabled, isFalse);
    expect(restart.extensionRepositories.singleWhere((item) => item.identity == second.identity).name, '备用仓库');
    for (final uri in ['http://example.test/index.json', 'https://user:secret@example.test/index.json']) {
      expect(() => a.preferences.setExtensionRepository(ExtensionRepository(
        format: first.format, index: Uri.parse(uri))), throwsA(isA<FormatException>()));
    }
  });

  test('absent plugin settings persist across owners and restore before source publication', () async {
    final a = await _Fixture.create();
    final b = await _Fixture.create();
    a.plugin.value = 'second';
    b.includePlugin = false;
    await b.controller.importRecords(await a.controller.exportRecords());
    final restarted = PortableSettingsOwner(preferences: b.preferences,
      loadTranslation: () async => b.translation, sources: () async => [],
      readPluginState: () async => b.files['plugins'],
      writePluginState: (value) async => b.files['plugins'] = value,
      readDownloadPolicy: () => b.policy, updateDownloadPolicy: (value) async => b.policy = value);
    await Future.wait([restarted.restorePluginSettings(b.plugin), restarted.restorePluginSettings(b.plugin)]);
    expect(b.plugin.value, 'second');
    expect(b.plugin.updates, 1, reason: 'activation notifications join the same restore');
    expect(b.files['plugins']!['entries'], isNotNull);
    await restarted.restorePluginSettings(b.plugin);
    expect(b.plugin.updates, 1, reason: 'completed restore does not replay on next publication');
    expect(b.plugin.actions, 0);
  });

  test('migrated repository observations do not override a remote choice as a new edit', () async {
    final a = await _Fixture.create();
    final b = await _Fixture.create();
    final repository = ExtensionRepository(format: ExternalComicPluginFormat.veneraJavaScript,
      index: Uri.https('migrated.example', '/index.json'), enabled: false);
    a.preferences.setExtensionRepository(repository);
    b.preferences.applyExtensionRepository(repository.identity, {'enabled': true}, modifiedAt: 0);
    final key = 'setting:repository\u0000' + repository.identity;
    final remote = await a.controller.exportRecords();
    final local = await b.controller.exportRecords();
    expect(local[key]!.time, 0);
    expect(mergeLibrarySync(local, remote)[key]!.data!['enabled'], isFalse);
    await b.owner.apply([remote[key]!], await b.owner.read());
    await b.controller.exportRecords();
    b.preferences.setExtensionRepository(ExtensionRepository(format: repository.format, index: repository.index));
    final edited = await b.controller.exportRecords();
    expect(edited[key]!.time, greaterThan(remote[key]!.time));
    expect(mergeLibrarySync(edited, remote)[key]!.data!['enabled'], isTrue);
  });

  test('repository capacity is checked before any backup owner is mutated', () async {
    final a = await _Fixture.create();
    final b = await _Fixture.create();
    a.preferences.setThemeMode(ThemeMode.light);
    a.preferences.setExtensionRepository(ExtensionRepository(
      format: ExternalComicPluginFormat.veneraJavaScript, index: Uri.https('new.example', '/index.json')));
    for (var i = 0; i < 256; i++) {
      b.preferences.setExtensionRepository(ExtensionRepository(
        format: ExternalComicPluginFormat.veneraJavaScript, index: Uri.https('existing.example', '/$i.json')));
    }
    final before = b.preferences.themeMode;
    await expectLater(b.controller.importRecords(await a.controller.exportRecords()),
      throwsA(isA<FormatException>()));
    expect(b.preferences.themeMode, before);
    expect(b.preferences.extensionRepositories, hasLength(256));
    final existing = b.preferences.extensionRepositories.first;
    final records = b.preferences.extensionRepositoryRecords;
    expect(() => b.preferences.replaceExtensionRepository(existing,
      existing.copyWith(index: Uri.https('replacement.example', '/index.json'))),
      throwsA(isA<FormatException>()));
    expect(b.preferences.extensionRepositoryRecords, records);
  });

  test('repository address edits publish one snapshot and sync old-index deletion with the named replacement', () async {
    final a = await _Fixture.create();
    final b = await _Fixture.create();
    Map<String, Object?>? persisted;
    await a.preferences.attach(read: () async => null, write: (value) async => persisted = value);
    final original = ExtensionRepository(format: ExternalComicPluginFormat.veneraJavaScript,
      index: Uri.https('raw.githubusercontent.com', '/alice/catalog/main/index.json'),
      enabled: false, name: '原仓库');
    a.preferences.setExtensionRepository(original);
    b.preferences.setExtensionRepository(original);
    final replacement = original.copyWith(
      index: Uri.https('raw.githubusercontent.com', '/alice/catalog/beta/index.json'), name: '测试仓库');
    final observations = <Map<String, Map<String, Object?>?>>[];
    void observe() => observations.add(a.preferences.extensionRepositoryRecords);
    a.preferences.addListener(observe);
    a.preferences.replaceExtensionRepository(original, replacement);
    a.preferences.removeListener(observe);
    expect(observations, hasLength(1));
    expect(observations.single[original.identity], isNull);
    expect(observations.single[replacement.identity], replacement.data);
    expect(a.preferences.extensionRepositoryTimes[original.identity],
      a.preferences.extensionRepositoryTimes[replacement.identity]);
    await a.preferences.flush();
    await b.controller.importRecords(await a.controller.exportRecords());
    expect(b.preferences.extensionRepositoryRecords[original.identity], isNull);
    expect(b.preferences.extensionRepositories.single.index, replacement.index);
    expect(b.preferences.extensionRepositories.single.name, '测试仓库');
    expect(b.preferences.extensionRepositories.single.enabled, isFalse);
    final restart = AppPreferencesController();
    addTearDown(restart.dispose);
    await restart.attach(read: () async => persisted, write: (_) async {});
    expect(restart.extensionRepositoryRecords[original.identity], isNull);
    expect(restart.extensionRepositories.single.data, replacement.data);
    final duplicate = replacement.copyWith(index: Uri.https('duplicate.example', '/index.json'));
    a.preferences.setExtensionRepository(duplicate);
    final before = a.preferences.extensionRepositoryRecords;
    expect(() => a.preferences.replaceExtensionRepository(replacement, duplicate),
      throwsA(isA<FormatException>()));
    expect(a.preferences.extensionRepositoryRecords, before);
  });

  test('source read failure preserves the last plugin value and concurrent user edits survive apply', () async {
    final f = await _Fixture.create();
    final baseline = await f.owner.read();
    final key = PortableSettingsOwner.pluginKey('venera:test', 'choice');
    f.plugin.value = 'second';
    await f.owner.rememberPluginChange(f.plugin.sourceId, f.plugin.setting, 'second');
    final record = LibrarySyncRecord(key: key, time: 10, writer: 'other',
      data: {'kind': 'select', 'value': 'first'});
    await f.owner.apply([record], baseline);
    expect(f.plugin.value, 'second');
    f.plugin.failReads = true;
    expect((await f.owner.read())[key]!.data!['value'], 'second');
  });

  test('invalid settings fail before a valid library record can be applied', () async {
    final f = await _Fixture.create();
    final theme = f.preferences.themeMode;
    final records = await f.controller.exportRecords();
    final global = records['setting:translation\u0000global']!;
    records[global.key] = LibrarySyncRecord(key: global.key, time: 10, writer: 'other',
      data: {...global.data!, 'apiKey': 'must-never-import'});
    records['comic:remote\u0000comic'] = LibrarySyncRecord(key: 'comic:remote\u0000comic',
      time: 10, writer: 'other', data: SavedComicRecord(sourceId: 'remote', comicId: 'comic',
        title: 'Unapplied', savedAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026)).toJson());
    await expectLater(f.controller.importRecords(records), throwsA(isA<FormatException>()));
    expect(await f.store.listSavedComics(), isEmpty);
    expect(f.preferences.themeMode, theme);
    expect(() => decodeImportedLibraryBackup(encodeLibrarySync(records, compress: false)),
      throwsA(isA<FormatException>()));
    expect(() => decodeImportedLibraryBackup(const MetadataGzipCodec().encode(
      List.filled(maxLibrarySyncBytes + 1, 32))), throwsA(isA<FormatException>()));
  });

  test('Android backup reads the staged file when provider size and bytes are empty', () async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = previousPlatform);
    final f = await _Fixture.create();
    final records = await f.controller.exportRecords();
    final file = File('${f.directory.path}/backup.json.gz');
    await file.writeAsBytes(const MetadataGzipCodec().encode(
      encodeLibrarySync(records, compress: false)));
    final selected = XFile.fromData(Uint8List(0), path: file.path, length: 0);
    expect(await selected.length(), 0, reason: 'the provider metadata can be stale');
    final imported = await readImportedLibraryBackup(selected);
    expect(imported.keys, unorderedEquals(records.keys));
    expect(imported['setting:translation\u0000global']!.fingerprint,
      records['setting:translation\u0000global']!.fingerprint);
    final oversized = await file.open(mode: FileMode.write);
    await oversized.truncate(maxLibrarySyncBytes + 1);
    await oversized.close();
    await expectLater(readImportedLibraryBackup(selected), throwsA(isA<LibrarySyncFormatException>()));
  });

  test('missing local-file progress survives restart and restores only when its chapter is available', () async {
    final f = await _Fixture.create();
    final record = LibrarySyncRecord(key: 'progress:local-folder\u0000chapter', time: 10, writer: 'backup',
      data: ReadingProgress(sourceId: 'local-folder', comicId: 'comic', chapterId: 'chapter',
        pageIndex: 1, subPageOffset: .25, readerMode: ReaderMode.paged,
        updatedAt: DateTime.utc(2026)).toJson());
    await f.controller.importRecords({record.key: record});
    expect(await f.store.list(), isEmpty);
    expect(f.files['pending-imports.json']!['records'], hasLength(1));
    await f.controller.close();
    f.controller.dispose();
    f.createController();
    final exported = await f.controller.exportRecords();
    expect(exported[record.key]!.data!['pageIndex'], 1);
    await f.store.upsertChapter(ImportedChapterRecord(directoryId: '/local',
      displayName: 'Local', sourceId: 'local-folder', comicId: 'comic', chapterId: 'chapter',
      sourceRevision: '1', importedAt: DateTime.now().toUtc(), pages: List.generate(2, (i) =>
        ImportedPageRecord(displayName: '$i.png', sourceId: '/local/$i.png', contentKindHint: ContentKindHint.png))));
    await f.controller.exportRecords();
    expect((await f.store.get('local-folder', 'chapter'))!.progress!.pageIndex, 1);
    expect(f.files['pending-imports.json']!['records'], isEmpty);
  });

  test('legacy JSON import preserves existing records and converts physical locators into placeholders', () async {
    final f = await _Fixture.create();
    final source = MemoryImportedLibraryStore();
    await source.open();
    addTearDown(source.close);
    final now = DateTime.utc(2026);
    await source.upsertSavedComic(SavedComicRecord(sourceId: 'remote', comicId: 'old',
      title: 'Old', savedAt: now, updatedAt: now));
    await source.upsertChapter(ImportedChapterRecord(directoryId: '/private',
      displayName: 'Old', sourceId: 'remote', comicId: 'old', chapterId: 'chapter',
      sourceRevision: '1', importedAt: now,
      pages: [const ImportedPageRecord(displayName: 'secret title',
        sourceId: 'https://example.test/image?credential=private', pageId: 'page',
        contentKindHint: ContentKindHint.png)]));
    await f.store.upsertSavedComic(SavedComicRecord(sourceId: 'remote', comicId: 'local',
      title: 'Local', savedAt: now, updatedAt: now));
    final payload = await buildImportedLibraryBackup(source);
    final records = decodeImportedLibraryBackup(utf8.encode(jsonEncode(payload)));
    await f.controller.importRecords(records);
    expect((await f.store.listSavedComics()).map((comic) => comic.comicId), containsAll(['old', 'local']));
    final chapter = (await f.store.get('remote', 'chapter'))!.chapter;
    expect(chapter.pages.single.sourceId, startsWith(importedChapterSummaryPageSourcePrefix));
    expect(chapter.pages.single.displayName, '1');
    expect(() => decodeImportedLibraryBackup(utf8.encode(jsonEncode({...payload,
      'savedComics': [for (var i = 0; i < 2; i++) (payload['savedComics'] as List).single]}))),
      throwsA(isA<FormatException>()));
  });

  testWidgets('file preview and cancellation never mutate settings or the library', (tester) async {
    final f = (await tester.runAsync(_Fixture.create))!;
    final records = (await tester.runAsync(f.controller.exportRecords))!;
    final global = records['setting:translation\u0000global']!;
    records[global.key] = LibrarySyncRecord(key: global.key, time: 10, writer: 'backup',
      data: {...global.data!, 'targetLanguage': 'en'});
    final app = records['setting:app\u0000global']!;
    f.preferences.setThemeMode(ThemeMode.dark);
    records[app.key] = LibrarySyncRecord(key: app.key, time: 10, writer: 'backup',
      data: f.preferences.readPortableSettings());
    f.preferences.setThemeMode(ThemeMode.system);
    final bytes = Uint8List.fromList(const MetadataGzipCodec().encode(encodeLibrarySync(records)));
    await tester.pumpWidget(MaterialApp(home: LibraryBackupImportScreen(controller: f.controller,
      selectFile: () async => XFile.fromData(bytes, name: 'fixture.json.gz'))));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(backupChooseFileKey));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (find.textContaining('翻译设置 ·').evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('翻译设置 ·'), findsOneWidget);
    expect(f.translation.values['targetLanguage'], 'zh-CN');
    await tester.scrollUntilVisible(find.byKey(const ValueKey('library-data-appSettings')), 200);
    await tester.tap(find.byKey(const ValueKey('library-data-appSettings')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(backupApplyKey), 200);
    await tester.tap(find.byKey(backupApplyKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(f.translation.values['targetLanguage'], 'zh-CN');
    await tester.tap(find.byKey(backupApplyKey));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '导入'));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (f.translation.values['targetLanguage'] != 'en' && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
      while (f.controller.busy && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    expect(f.translation.values['targetLanguage'], 'en');
    expect(f.preferences.themeMode, ThemeMode.system, reason: 'unchecked app settings stay local');
  });
}

final class _Fixture {
  _Fixture(this.directory);
  final Directory directory;
  final preferences = AppPreferencesController();
  final translation = ComicTranslationSettings();
  final store = MemoryImportedLibraryStore();
  final plugin = _Plugin();
  final files = <String, Map<String, Object?>>{};
  bool includePlugin = true;
  int translationReads = 0;
  int sourceReads = 0;
  int libraryApplications = 0;
  var policy = const WholeComicQueuePolicy();
  late final PortableSettingsOwner owner;
  late WebDavSyncController controller;

  static Future<_Fixture> create() async {
    final f = _Fixture(await Directory.systemTemp.createTemp('zic-portable-settings-'));
    await f.store.open();
    await f.translation.init(f.directory.path);
    f.owner = PortableSettingsOwner(preferences: f.preferences,
      loadTranslation: () async { f.translationReads++; return f.translation; },
      sources: () async { f.sourceReads++; return f.includePlugin ? [f.plugin] : []; },
      readPluginState: () async => f.files['plugins'],
      writePluginState: (value) async => f.files['plugins'] = value,
      readDownloadPolicy: () => f.policy, updateDownloadPolicy: (policy) async => f.policy = policy);
    f.createController();
    addTearDown(() async {
      await f.controller.close();
      f.controller.dispose();
      f.preferences.dispose();
      f.translation.dispose();
      await f.store.close();
      await f.directory.delete(recursive: true);
    });
    return f;
  }

  void createController() {
    controller = WebDavSyncController(client: WebDavClient(NetLane(maxActive: 1)),
      preferences: preferences, portableSettings: owner, storageRoot: () async => directory.path,
      read: (name) async => files[name], write: (name, data) async => files[name] = data,
      readLibrary: () => readLibrarySyncSnapshot(store),
      applyLibrary: (records, expected) {
        libraryApplications++;
        return applyLibrarySyncRecords(store, records, expected);
      });
  }
}

final class _Plugin extends Fake implements BrowsableComicSource, ConfigurableComicSource {
  @override
  String get sourceId => 'venera:test';
  String value = 'first';
  bool failReads = false;
  int actions = 0;
  int updates = 0;
  ComicSourceSetting get setting => ComicSourceSetting(key: 'choice', title: 'Choice',
    kind: ComicSourceSettingKind.select, value: value,
    choices: [const ComicSourceSettingChoice(value: 'first', label: 'First'),
      const ComicSourceSettingChoice(value: 'second', label: 'Second')]);
  @override
  Future<List<ComicSourceSetting>> loadSettings() async {
    if (failReads) throw StateError('Unavailable');
    return [setting,
      ComicSourceSetting(key: 'loginToken', title: 'Token', kind: ComicSourceSettingKind.text,
        value: 'private-login-token', sensitive: true),
      ComicSourceSetting(key: 'action', title: 'Action', kind: ComicSourceSettingKind.action, value: 'Run')];
  }
  @override
  Future<void> updateSetting(String key, Object next) async {
    if (key == 'action') { actions++; return; }
    if (key != 'choice') throw StateError('Unexpected setting');
    updates++;
    value = next as String;
  }
}

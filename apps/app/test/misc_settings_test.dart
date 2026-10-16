import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/reader.dart';
import 'package:reader_runtime/reader_runtime.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:telemetry/telemetry.dart';
import 'package:zic/app_preferences.dart';
import 'package:zic/app_settings_screen.dart';
import 'package:zic/debug_trace.dart';
import 'package:zic/debug_trace_export.dart';
import 'package:zic/debug_trace_screen.dart';
import 'package:zic/home_shell.dart';
import 'package:zic/library_backup.dart';
import 'package:zic/app.dart';
import 'package:zic/misc_page.dart';
import 'package:zic/reader_preferences.dart';

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 80,
}) async {
  for (var frame = 0; frame < maxFrames; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure('Timed out waiting for $finder');
}

final class _SnapshotOnlyImportedLibraryStore
    implements ImportedLibraryStore, ImportedLibraryBackupSnapshotStore {
  int snapshotReads = 0;

  @override
  Future<ImportedLibraryBackupSnapshot> readLibraryBackupSnapshot() async {
    snapshotReads++;
    return const ImportedLibraryBackupSnapshot(
      entries: <ImportedLibraryEntry>[],
      savedComics: <SavedComicRecord>[],
      categories: <LibraryCategory>[],
      comicPreferences: <ComicPreference>[],
      chapterReadStates: <ChapterReadState>[],
      sourcePreferences: <ComicSourcePreference>[],
      migrationIssues: <LibraryMigrationIssue>[],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw StateError('backup used a legacy per-section library read');
  }
}

void main() {
  test('debug trace export directory stays under Downloads', () {
    expect(normalizeDebugTraceExportDirectory(' Debug/Reader '), 'Debug/Reader');
    expect(normalizeDebugTraceExportDirectory('../escape'), 'Debug');
    expect(normalizeDebugTraceExportDirectory(''), 'Debug');
    expect(debugTraceExportDisplayPath('Debug'), 'Download/Debug');
  });

  testWidgets('fourth navigation page exposes misc settings and diagnostics', (
    tester,
  ) async {
    await tester.pumpWidget(const App());
    final miscDestination = find.byIcon(Icons.more_horiz);
    await _pumpUntilFound(tester, miscDestination);
    await tester.tap(miscDestination);
    await tester.pump();

    expect(find.byKey(miscPageKey), findsOneWidget);
    expect(find.byKey(miscQuickSettingsKey), findsOneWidget);
    expect(find.byKey(miscSettingsEntryKey), findsOneWidget);
    expect(find.byKey(miscAboutEntryKey), findsOneWidget);
    expect(find.byKey(miscDebugTraceEntryKey), findsOneWidget);

    await tester.tap(find.byKey(miscSettingsEntryKey));
    await tester.pump();
    await _pumpUntilFound(tester, find.byKey(settingsScreenKey));

    expect(find.byKey(settingsDataEntryKey), findsOneWidget);
    expect(find.byKey(settingsNetworkEntryKey), findsOneWidget);
    expect(find.byKey(settingsBookshelfEntryKey), findsOneWidget);
    expect(find.byKey(settingsReadingEntryKey), findsOneWidget);
    expect(find.byKey(settingsDownloadEntryKey), findsOneWidget);
    expect(find.byKey(settingsAppearanceEntryKey), findsOneWidget);
    expect(find.byKey(settingsDebugModeKey), findsOneWidget);

    await tester.tap(find.byKey(settingsDataEntryKey));
    await tester.pump();
    await _pumpUntilFound(tester, find.byKey(dataSettingsScreenKey));
    expect(find.byKey(dataFileAccessSettingsKey), findsOneWidget);
    expect(find.text('文件读写设置'), findsOneWidget);
    expect(find.textContaining('所有文件访问'), findsOneWidget);
  });

  testWidgets('Debug mode hides diagnostic entry surfaces and stops trace recording', (
    tester,
  ) async {
    final preferences = AppPreferencesController();
    final trace = DebugTraceLog();
    addTearDown(preferences.dispose);
    addTearDown(trace.dispose);
    preferences.setDebugModeEnabled(false);

    await tester.pumpWidget(
      App(
        preferences: preferences,
        debugTrace: trace,
        persistMissingPreferences: false,
      ),
    );
    await _pumpUntilFound(tester, find.byIcon(Icons.more_horiz));
    expect(trace.enabled, isFalse);
    expect(find.byKey(homeDiagnosticsKey), findsNothing);
    expect(find.byKey(homeTraceQuickExportKey), findsNothing);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pump();
    expect(find.byKey(miscDebugTraceEntryKey), findsNothing);
    expect(find.text('记录 Debug trace'), findsNothing);

    await tester.tap(find.byKey(miscSettingsEntryKey));
    await tester.pump();
    await _pumpUntilFound(tester, find.byKey(settingsDebugModeKey));
    await tester.ensureVisible(find.byKey(settingsDebugModeKey));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(settingsDebugModeKey));
    await tester.pump();
    expect(preferences.debugModeEnabled, isTrue);
    expect(trace.enabled, isTrue);

    await tester.pageBack();
    await tester.pump();
    expect(find.byKey(miscDebugTraceEntryKey), findsOneWidget);
    expect(find.text('记录 Debug trace'), findsOneWidget);
  });

  testWidgets('reading zoom stages use sliders and status bar exposes three modes',
      (tester) async {
    final preferences = AppPreferencesController();
    addTearDown(preferences.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ReadingSettingsScreen(preferences: preferences),
      ),
    );

    await tester.scrollUntilVisible(
      find.byKey(readingShowStatusBarKey),
      320,
    );
    final statusBarControl =
        tester.widget<SegmentedButton<ReaderSystemStatusBarMode>>(
      find.descendant(
        of: find.byKey(readingShowStatusBarKey),
        matching: find.byType(SegmentedButton<ReaderSystemStatusBarMode>),
      ),
    );
    expect(statusBarControl.segments, hasLength(3));
    expect(
      statusBarControl.selected,
      <ReaderSystemStatusBarMode>{ReaderSystemStatusBarMode.show},
    );
    statusBarControl.onSelectionChanged?.call(
      <ReaderSystemStatusBarMode>{ReaderSystemStatusBarMode.followControls},
    );
    await tester.pump();
    expect(
      preferences.systemStatusBarMode,
      ReaderSystemStatusBarMode.followControls,
    );

    await tester.scrollUntilVisible(
      find.byKey(readingZoomStageFirstKey),
      320,
    );
    final firstSlider = tester.widget<Slider>(
      find.descendant(
        of: find.byKey(readingZoomStageFirstKey),
        matching: find.byType(Slider),
      ),
    );
    await tester.scrollUntilVisible(
      find.byKey(readingZoomStageSecondKey),
      320,
    );
    final secondSlider = tester.widget<Slider>(
      find.descendant(
        of: find.byKey(readingZoomStageSecondKey),
        matching: find.byType(Slider),
      ),
    );
    expect(firstSlider.min, 1.25);
    expect(firstSlider.max, 4);
    expect(secondSlider.min, 1.5);
    expect(secondSlider.max, 8);
    firstSlider.onChanged?.call(2.25);
    await tester.pump();
    final updatedSecondSlider = tester.widget<Slider>(
      find.descendant(
        of: find.byKey(readingZoomStageSecondKey),
        matching: find.byType(Slider),
      ),
    );
    expect(updatedSecondSlider.min, 2.25);
    updatedSecondSlider.onChanged?.call(3.75);
    await tester.pump();
    expect(preferences.pagedReaderSettings.zoomStageFirst, 2.25);
    expect(preferences.pagedReaderSettings.zoomStageSecond, 3.75);
    expect(preferences.continuousReaderSettings.zoomStageFirst, 1.5);
    expect(preferences.continuousReaderSettings.zoomStageSecond, 2.0);
  });

  testWidgets('paged and continuous cross-chapter reading settings are independent',
      (tester) async {
    final preferences = AppPreferencesController();
    addTearDown(preferences.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ReadingSettingsScreen(preferences: preferences),
      ),
    );
    final scrollable = find.byType(Scrollable).first;

    await tester.scrollUntilVisible(
      find.byKey(readingPagedContinuousReadingKey),
      320,
      scrollable: scrollable,
    );
    final pagedContinuous = tester.widget<SwitchListTile>(
      find.byKey(readingPagedContinuousReadingKey),
    );
    expect(pagedContinuous.value, isFalse);
    pagedContinuous.onChanged?.call(true);
    await tester.pump();
    expect(preferences.pagedReaderSettings.crossChapterReading, isTrue);
    expect(preferences.continuousReaderSettings.crossChapterReading, isFalse);

    await tester.scrollUntilVisible(
      find.byKey(readingContinuousContinuousReadingKey),
      320,
      scrollable: scrollable,
    );
    final continuousContinuous = tester.widget<SwitchListTile>(
      find.byKey(readingContinuousContinuousReadingKey),
    );
    expect(continuousContinuous.value, isFalse);
    continuousContinuous.onChanged?.call(true);
    await tester.pump();
    expect(preferences.pagedReaderSettings.crossChapterReading, isTrue);
    expect(preferences.continuousReaderSettings.crossChapterReading, isTrue);
  });

  testWidgets('network prefetch budget updates without leaving the settings page', (
    tester,
  ) async {
    await tester.pumpWidget(const App());
    await _pumpUntilFound(tester, find.byIcon(Icons.more_horiz));
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pump();
    await _pumpUntilFound(tester, find.byKey(miscSettingsEntryKey));
    await tester.tap(find.byKey(miscSettingsEntryKey));
    await tester.pump();
    await _pumpUntilFound(tester, find.byKey(settingsNetworkEntryKey));
    await tester.tap(find.byKey(settingsNetworkEntryKey));
    await tester.pump();
    await _pumpUntilFound(tester, find.byKey(networkSettingsScreenKey));

    final conflictTrust = tester.widget<SwitchListTile>(
      find.byKey(networkCachedCarrierConflictTrustKey),
    );
    expect(conflictTrust.value, isTrue);
    expect(find.text('50 MB'), findsOneWidget);
    await tester.tap(find.byKey(networkReaderPrefetchBudgetKey));
    await tester.pumpAndSettle();
    final field = find.widgetWithText(TextFormField, '大小（MB）');
    expect(field, findsOneWidget);
    await tester.enterText(field, '25');
    await tester.tap(find.widgetWithText(FilledButton, '设置'));
    await tester.pump();

    expect(find.byKey(networkSettingsScreenKey), findsOneWidget);
    expect(find.text('25 MB'), findsOneWidget);
    await tester.tap(find.byKey(networkCachedCarrierConflictTrustKey));
    await tester.pump();
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(networkCachedCarrierConflictTrustKey),
          )
          .value,
      isFalse,
    );
  });

  testWidgets('download policy settings follow current generation binding', (
    tester,
  ) async {
    final changes = ChangeNotifier();
    addTearDown(changes.dispose);
    var snapshot = const WholeComicQueueSnapshot(
      policy: WholeComicQueuePolicy(),
      environment: WholeComicQueueEnvironment.assumedAvailable(),
      jobs: <WholeComicQueueJobSnapshot>[],
    );
    WholeComicQueuePolicy? written;
    final binding = WholeComicPolicySettingsBinding(
      changes: changes,
      readSnapshot: () => snapshot,
      updatePolicy: (policy) async {
        written = policy;
      },
    );

    await tester.pumpWidget(
      MaterialApp(home: DownloadSettingsScreen(policyBinding: binding)),
    );
    var slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.value, 1);

    snapshot = const WholeComicQueueSnapshot(
      policy: WholeComicQueuePolicy(concurrency: 3),
      environment: WholeComicQueueEnvironment.assumedAvailable(),
      jobs: <WholeComicQueueJobSnapshot>[],
    );
    changes.notifyListeners();
    await tester.pump();
    slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.value, 3);

    slider.onChanged!(4);
    await tester.pump();
    expect(written?.concurrency, 4);
  });

  testWidgets('data settings follow current runtime generation binding', (
    tester,
  ) async {
    final changes = ChangeNotifier();
    final preferences = AppPreferencesController();
    addTearDown(changes.dispose);
    addTearDown(preferences.dispose);
    ResourceCacheStats emptyStats() => ResourceCacheStats(
      entries: 0,
      inFlight: 0,
      weight: 0,
      hits: 0,
      misses: 0,
      evictions: 0,
      expirations: 0,
      persistentHits: 0,
      persistentMisses: 0,
      byKind: <ResourceCacheKind, ResourceCacheKindStats>{},
    );
    ResourceCacheUsage emptyUsage() => ResourceCacheUsage(
      responses: emptyStats(),
    );
    ResourceCacheMaintenanceReport emptyReport() =>
        ResourceCacheMaintenanceReport(
          responseReleasedBytes: 0,
          persistentResponseReleasedBytes: 0,
          responses: emptyStats(),
        );

    var generation = 1;
    var storageRoot = '/root-a';
    var clearGeneration = 0;
    var trimGeneration = 0;
    final binding = DataSettingsRuntimeBinding(
      changes: changes,
      readStorageRoot: () => storageRoot,
      canChangeChapterDownloadDirectory: () => true,
      changeChapterDownloadDirectory: ({directory, required migrateFiles}) async => null,
      inspectCache: () async => emptyUsage(),
      clearCache: () async {
        clearGeneration = generation;
        return DataSettingsCacheMutationResult(
          report: emptyReport(),
          usage: emptyUsage(),
        );
      },
      updateCachePolicyAndTrim: (policy) async {
        trimGeneration = generation;
        return DataSettingsCacheMutationResult(
          report: emptyReport(),
          usage: emptyUsage(),
        );
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: DataSettingsScreen(
          preferences: preferences,
          runtime: binding,
          exportBackup: () async => null,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    expect(find.text('/root-a'), findsOneWidget);

    generation = 2;
    storageRoot = '/root-b';
    changes.notifyListeners();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    expect(find.text('/root-b'), findsOneWidget);

    await binding.clearCache();
    expect(clearGeneration, 2);
    await binding.updateCachePolicyAndTrim(
      ResourceCacheMaintenancePolicy.forArtifactLimitBytes(256 * 1024 * 1024),
    );
    expect(trimGeneration, 2);
  });

  testWidgets('appearance settings exposes AMOLED dark mode', (tester) async {
    final preferences = AppPreferencesController();
    addTearDown(preferences.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AppearanceSettingsScreen(preferences: preferences),
      ),
    );

    expect(find.byKey(appearanceAmoledKey), findsOneWidget);
    expect(preferences.amoledDarkTheme, isFalse);
    await tester.tap(find.byKey(appearanceAmoledKey));
    await tester.pump();
    expect(preferences.amoledDarkTheme, isTrue);
  });

  test('theme invalidation ignores comic Reader settings', () {
    final preferences = AppPreferencesController();
    addTearDown(preferences.dispose);
    var broadNotifications = 0;
    var themeNotifications = 0;
    preferences.addListener(() => broadNotifications++);
    preferences.themeChanges.addListener(() => themeNotifications++);

    preferences.setComicReaderSettings(
      'source-a',
      'comic-a',
      const ComicReaderSettings(
        adaptiveProfile: AdaptiveReaderProfile(
          direction: ReadingDirection.ltr,
          confidence: 1,
          basis: 'decoded-animation',
          animated: true,
          samples: 4,
          metadataFingerprint: 7,
          modelVersion: AdaptiveReaderProfile.currentModelVersion,
        ),
      ),
    );

    expect(broadNotifications, 1);
    expect(themeNotifications, 0);

    preferences.setThemeMode(ThemeMode.light);
    expect(broadNotifications, 2);
    expect(themeNotifications, 1);

    preferences.setAmoledDarkTheme(true);
    expect(broadNotifications, 3);
    expect(themeNotifications, 2);
  });

  testWidgets('App shell rebuilds only for theme preferences', (tester) async {
    final preferences = AppPreferencesController();
    addTearDown(preferences.dispose);
    await tester.pumpWidget(App(preferences: preferences));
    await _pumpUntilFound(tester, find.byType(MaterialApp));
    final initial = tester.widget<MaterialApp>(find.byType(MaterialApp));

    preferences.setComicReaderSettings(
      'source-a',
      'comic-a',
      const ComicReaderSettings(
        adaptiveProfile: AdaptiveReaderProfile(
          direction: ReadingDirection.ltr,
          confidence: 1,
          basis: 'decoded-animation',
          animated: true,
          samples: 4,
          metadataFingerprint: 11,
          modelVersion: AdaptiveReaderProfile.currentModelVersion,
        ),
      ),
    );
    await tester.pump();
    expect(
      identical(tester.widget<MaterialApp>(find.byType(MaterialApp)), initial),
      isTrue,
    );

    preferences.setThemeMode(ThemeMode.light);
    await tester.pump();
    expect(
      identical(tester.widget<MaterialApp>(find.byType(MaterialApp)), initial),
      isFalse,
    );
  });

  test('application preferences load and persist through injected storage', () async {
    final controller = AppPreferencesController();
    addTearDown(controller.dispose);
    Map<String, Object?>? written;

    await controller.attach(
      read: () async => <String, Object?>{
        'themeMode': 'light',
        'amoledDarkTheme': true,
        'debugModeEnabled': false,
        'debugTraceEnabled': false,
        'shelfSourceFilter': 'remote',
        'shelfSortMode': 'title',
        'shelfView': 'list',
        'defaultReaderMode': 'continuous',
        'readerStartsImmersive': false,
        'readerPagedDirectionPreference': 'rtl',
        'systemStatusBarMode': 'hide',
        'adaptiveReaderEnabled': true,
        'defaultVerticalStitch': true,
        'defaultZoomStage1': 3.0,
        'defaultZoomStage2': 5.0,
        'longPressZoomEnabled': false,
        'longPressZoomScale': 2.75,
        'longPressZoomRestoreOnRelease': false,
        'longPressZoomMoveMode': 'focus',
        'longPressZoomPanRatio': 1.5,
        'longPressZoomLimitToViewport': false,
        'doubleTapZoomOrigin': 'snap',
        'zoomDecodeBoost': false,
        'detailsPreviewMaxItemsPerRow': 6,
        'networkUserAgent': 'fixture-network-agent',
        'debugTraceExportDirectory': 'Diagnostics/Trace',
        'readerPrefetchReadBudgetMiB': 72,
        'cachedCarrierTrustMode': 'reuseThenRefresh',
        'pluginTrustConflictingHistoricalCarriers': <String, Object?>{
          'venera:fixture-plugin': true,
          'mihon:strict-plugin': false,
          'bad': 'yes',
        },
        'animatedWebpPrefetchBudgetMiB': 88, // ignored legacy dev.247/248 key
        'sourceDownloadDirectories': <String, Object?>{
          'venera:alpha': '/data/downloads-alpha',
          'mihon:beta': 42, // invalid entries are dropped
          ' ': '/data/ignored', // blank keys are dropped
        },
        'sourceAdaptiveWebtoonWeights': <String, Object?>{
          'venera:legacy': 0.8,
          'mihon:clamped': 2.0,
          'venera:neutral-legacy': 0.0,
          'venera:override': 1.0,
          'bad': 'high',
          ' ': 0.5,
        },
        'sourceAdaptiveWebtoonConfidences': <String, Object?>{
          'venera:alpha': 0.2,
          'venera:zero': 0.0,
          'venera:override': 0.25,
          'bad': 'high',
          ' ': 0.5,
        },
        'sourceSearchHistory': <Object?>['Alpha', 'beta', 'alpha'],
        'comicReaderSettings': <String, Object?>{
          comicReaderSettingsIdentity('source-a', 'comic-a'):
              <String, Object?>{
            'enabled': true,
            'directionOverride': 'rtl',
            'verticalStitch': true,
            'adaptiveEnabled': false,
            'adaptiveProfile': <String, Object?>{
              'direction': 'rtl',
              'confidence': 0.91,
              'basis': 'page-geometry',
              'animated': false,
              'samples': 3,
              'modelVersion': AdaptiveReaderProfile.currentModelVersion,
            },
          },
        },
      },
      write: (values) async => written = Map<String, Object?>.from(values),
    );

    expect(controller.themeMode, ThemeMode.light);
    expect(controller.amoledDarkTheme, isTrue);
    expect(controller.debugModeEnabled, isFalse);
    expect(controller.debugTraceEnabled, isFalse);
    expect(controller.shelfSourceFilter, ShelfSourceFilter.remote);
    expect(controller.shelfSortMode, LibrarySortMode.title);
    expect(controller.shelfView, ShelfViewPreference.list);
    expect(controller.defaultReaderMode, ReaderMode.continuous);
    expect(controller.readerStartsImmersive, isFalse);
    expect(
      controller.readerPagedDirectionPreference,
      ReaderPagedDirectionPreference.rtl,
    );
    expect(controller.systemStatusBarMode, ReaderSystemStatusBarMode.hide);
    expect(controller.adaptiveReaderEnabled, isTrue);
    expect(controller.defaultVerticalStitch, isTrue);
    expect(controller.pagedReaderSettings.zoomStageFirst, 3.0);
    expect(controller.pagedReaderSettings.zoomStageSecond, 5.0);
    expect(controller.pagedReaderSettings.longPressZoomEnabled, isFalse);
    expect(controller.pagedReaderSettings.longPressZoomScale, 2.75);
    expect(
      controller.pagedReaderSettings.longPressZoomRestoreOnRelease,
      isFalse,
    );
    expect(
      controller.pagedReaderSettings.longPressZoomMoveMode,
      ReaderLongPressMoveMode.focus,
    );
    expect(controller.pagedReaderSettings.longPressZoomPanRatio, 1.5);
    expect(
      controller.pagedReaderSettings.longPressZoomLimitToViewport,
      isFalse,
    );
    expect(
      controller.pagedReaderSettings.doubleTapZoomOrigin,
      ReaderDoubleTapZoomOrigin.snap,
    );
    expect(controller.pagedReaderSettings.zoomDecodeBoost, isFalse);
    expect(controller.continuousReaderSettings.longPressZoomEnabled, isFalse);
    expect(controller.detailsPreviewMaxItemsPerRow, 6);
    expect(controller.networkUserAgent, 'fixture-network-agent');
    expect(controller.debugTraceExportDirectory, 'Diagnostics/Trace');
    expect(controller.chapterDownloadDirectoryOverride, isNull);
    expect(controller.chapterDownloadDirectoryPendingMoveFrom, isNull);
    expect(controller.cacheLimitMb, defaultCacheLimitMb);
    expect(controller.readerPrefetchReadBudgetMiB, 72);
    expect(
      controller.cachedCarrierTrustMode,
      CachedCarrierTrustMode.reuseThenRefresh,
    );
    expect(controller.trustConflictingHistoricalCarriersByDefault, isTrue);
    expect(
      controller.trustConflictingHistoricalCarriersForPlugin(
        'venera:fixture-plugin',
      ),
      isTrue,
    );
    expect(
      controller.trustConflictingHistoricalCarriersForPlugin(
        'mihon:strict-plugin',
      ),
      isFalse,
    );
    expect(
      controller.sourceDownloadDirectoryFor('venera:alpha'),
      '/data/downloads-alpha',
    );
    expect(controller.sourceDownloadDirectoryFor('mihon:beta'), isNull);
    expect(controller.sourceDownloadDirectoryFor('unknown'), isNull);
    expect(controller.sourceAdaptiveWebtoonConfidenceFor('venera:alpha'), 0.2);
    expect(controller.sourceAdaptiveWebtoonConfidenceFor('venera:zero'), 0.0);
    expect(controller.sourceAdaptiveWebtoonConfidenceFor('venera:legacy'), 0.9);
    expect(controller.sourceAdaptiveWebtoonConfidenceFor('mihon:clamped'), 1.0);
    expect(controller.sourceAdaptiveWebtoonConfidenceFor('venera:override'), 0.25);
    expect(
      controller.sourceAdaptiveWebtoonConfidenceFor('venera:neutral-legacy'),
      0.5,
    );
    expect(controller.sourceAdaptiveWebtoonConfidenceFor('unknown'), 0.5);
    expect(
      controller
          .readerSessionSettingsFor('venera:alpha', 'comic')
          .sourceWebtoonConfidence,
      0.2,
    );
    expect(
      controller
          .readerSessionSettingsFor('venera:alpha', 'comic')
          .pagedDirectionPreference,
      ReaderPagedDirectionPreference.rtl,
    );
    expect(
      controller
          .readerSessionSettingsFor('venera:alpha', 'comic')
          .systemStatusBarMode,
      ReaderSystemStatusBarMode.hide,
    );
    expect(
      controller
          .readerSessionSettingsFor('venera:alpha', 'comic')
          .paged
          .effectiveLongPressZoomScale,
      2.75,
    );
    expect(controller.sourceSearchHistory, <String>['Alpha', 'beta']);
    expect(
      controller.comicReaderSettingsFor('source-a', 'comic-a'),
      const ComicReaderSettings(
        enabled: true,
        directionOverride: ReadingDirection.rtl,
        verticalStitchOverride: true,
        adaptiveEnabled: false,
        adaptiveProfile: const AdaptiveReaderProfile(
          direction: ReadingDirection.rtl,
          confidence: 0.91,
          basis: 'page-geometry',
          samples: 3,
        ),
      ),
    );

    controller.setThemeMode(ThemeMode.dark);
    controller.setAmoledDarkTheme(false);
    controller.setDebugModeEnabled(true);
    controller.setShelfSortMode(LibrarySortMode.custom);
    controller.setDetailsPreviewMaxItemsPerRow(4);
    controller.setNetworkUserAgent('custom-network-agent');
    controller.setDebugTraceExportDirectory('Debug/Reader');
    controller.setChapterDownloadDirectoryOverride('/data/downloads');
    controller.setChapterDownloadDirectoryPendingMoveFrom('/data/old');
    controller.setChapterDownloadDirectoryPendingMoveProtocol(
      'replica-direct-v1',
    );
    controller.setCacheLimitMb(1024);
    controller.setReaderPrefetchReadBudgetMiB(64);
    controller.setCachedCarrierTrustMode(CachedCarrierTrustMode.trustCached);
    controller.setTrustConflictingHistoricalCarriersByDefault(false);
    controller.setPluginTrustConflictingHistoricalCarriers(
      'mihon:fixture-plugin',
      true,
    );
    controller.setSourceDownloadDirectory('venera:gamma', '/data/gamma');
    controller.setSourceAdaptiveWebtoonConfidence('venera:gamma', 0.1);
    controller.setReaderPagedDirectionPreference(
      ReaderPagedDirectionPreference.source,
    );
    controller.setSystemStatusBarMode(
      ReaderSystemStatusBarMode.followControls,
    );
    controller.setReaderModeSettings(
      ReaderMode.paged,
      controller.pagedReaderSettings.copyWith(
        longPressZoomScale: 3.25,
        longPressZoomRestoreOnRelease: true,
        longPressZoomMoveMode: ReaderLongPressMoveMode.drag,
        longPressZoomPanRatio: 2.0,
        longPressZoomLimitToViewport: true,
        doubleTapZoomOrigin: ReaderDoubleTapZoomOrigin.focus,
      ),
    );
    controller.rememberSourceSearch('Gamma');
    controller.acknowledgeComicVersionNotice(
      'source-a',
      'comic-old',
      'comic-new',
    );
    controller.setComicReaderSettings(
      'source-b',
      'comic-b',
      const ComicReaderSettings(
        enabled: true,
        directionOverride: ReadingDirection.vertical,
        verticalStitchOverride: true,
      ),
    );
    await controller.flush();

    expect(written?['themeMode'], 'dark');
    expect(written?['amoledDarkTheme'], isFalse);
    expect(written?['debugModeEnabled'], isTrue);
    expect(written?['shelfSortMode'], 'custom');
    expect(written?['version'], 9);
    expect(written?['readerPagedDirectionPreference'], 'source');
    expect(written?['systemStatusBarMode'], 'followControls');
    expect(written?.containsKey('showSystemStatusBar'), isFalse);
    final writtenModeSettings = written?['readerModeSettings']! as Map;
    final writtenPagedSettings = writtenModeSettings['paged']! as Map;
    expect(writtenPagedSettings['longPressZoomScale'], 3.25);
    expect(written?['detailsPreviewMaxItemsPerRow'], 4);
    expect(written?['networkUserAgent'], 'custom-network-agent');
    expect(written?['debugTraceExportDirectory'], 'Debug/Reader');
    expect(written?['chapterDownloadDirectoryOverride'], '/data/downloads');
    expect(
      written?['chapterDownloadDirectoryPendingMoveFrom'],
      '/data/old',
    );
    expect(
      written?['chapterDownloadDirectoryPendingMoveProtocol'],
      'replica-direct-v1',
    );
    expect(written?['cacheLimitMb'], 1024);
    expect(written?['readerPrefetchReadBudgetMiB'], 64);
    expect(written?['cachedCarrierTrustMode'], 'trustCached');
    expect(
      written?['trustConflictingHistoricalCarriersByDefault'],
      isFalse,
    );
    expect(
      written?['pluginTrustConflictingHistoricalCarriers'],
      <String, bool>{
        'venera:fixture-plugin': true,
        'mihon:strict-plugin': false,
        'mihon:fixture-plugin': true,
      },
    );
    expect(
      written?['sourceDownloadDirectories'],
      <String, String>{
        'venera:alpha': '/data/downloads-alpha',
        'venera:gamma': '/data/gamma',
      },
    );
    expect(
      written?['sourceAdaptiveWebtoonConfidences'],
      <String, double>{
        'venera:alpha': 0.2,
        'venera:zero': 0.0,
        'venera:legacy': 0.9,
        'mihon:clamped': 1.0,
        'venera:override': 0.25,
        'venera:gamma': 0.1,
      },
    );
    expect(written?.containsKey('sourceAdaptiveWebtoonWeights'), isFalse);
    expect(writtenPagedSettings['longPressZoomRestoreOnRelease'], true);
    expect(writtenPagedSettings['longPressZoomMoveMode'], 'drag');
    expect(writtenPagedSettings['longPressZoomPanRatio'], 2.0);
    expect(writtenPagedSettings['longPressZoomLimitToViewport'], true);
    expect(writtenPagedSettings['doubleTapZoomOrigin'], 'focus');
    expect(written?.containsKey('animatedWebpPrefetchBudgetMiB'), isFalse);
    expect((written?['sourceSearchHistory']! as List).first, 'Gamma');
    expect(
      written?['acknowledgedComicVersionNotices'],
      contains(
        comicVersionNoticeIdentity('source-a', 'comic-old', 'comic-new'),
      ),
    );
    final comicSettings = written?['comicReaderSettings']! as Map;
    expect(
      (comicSettings[comicReaderSettingsIdentity('source-b', 'comic-b')]
              as Map)['directionOverride'],
      'vertical',
    );
  });

  test('mode-scoped reader settings load and persist independently', () async {
    final controller = AppPreferencesController();
    addTearDown(controller.dispose);
    Map<String, Object?>? written;

    await controller.attach(
      read: () async => <String, Object?>{
        'readerModeSettings': <String, Object?>{
          'paged': <String, Object?>{
            'crossChapterReading': true,
            'zoomStage1': 1.75,
            'zoomStage2': 2.75,
            'longPressZoomEnabled': true,
            'longPressZoomScale': 2.5,
            'longPressZoomRestoreOnRelease': true,
            'longPressZoomMoveMode': 'drag',
            'longPressZoomPanRatio': 1.25,
            'longPressZoomLimitToViewport': true,
            'doubleTapZoomOrigin': 'snap',
            'zoomDecodeBoost': false,
            'gestureActions': <String, Object?>{
              'singleTap': <String, Object?>{
                'pageAnimation': false,
                'screenRetainFraction': 0.2,
                'zones': <String>[
                  'previousPage',
                  'defaultBehavior',
                  'nextPage',
                  'previousChapter',
                  'defaultBehavior',
                  'nextChapter',
                  'defaultBehavior',
                  'defaultBehavior',
                  'defaultBehavior',
                ],
                'grid': <String, Object?>{
                  'columns': <double>[0.25, 0.7],
                  'rows': <double>[0.2, 0.75],
                },
              },
            },
          },
          'continuous': <String, Object?>{
            'crossChapterReading': false,
            'zoomStage1': 2.25,
            'zoomStage2': 3.5,
            'longPressZoomEnabled': false,
            'longPressZoomScale': 3.0,
            'longPressZoomRestoreOnRelease': false,
            'longPressZoomMoveMode': 'focus',
            'longPressZoomPanRatio': 0.75,
            'longPressZoomLimitToViewport': false,
            'doubleTapZoomOrigin': 'focus',
            'zoomDecodeBoost': true,
          },
        },
      },
      write: (values) async => written = Map<String, Object?>.from(values),
    );

    expect(controller.pagedReaderSettings.crossChapterReading, isTrue);
    expect(controller.pagedReaderSettings.zoomStageFirst, 1.75);
    expect(controller.pagedReaderSettings.doubleTapZoomOrigin,
        ReaderDoubleTapZoomOrigin.snap);
    expect(controller.pagedReaderSettings.zoomDecodeBoost, isFalse);
    expect(controller.pagedReaderSettings.singleTapPageAnimation, isFalse);
    expect(
      controller.pagedReaderSettings.singleTapScreenRetainFraction,
      0.2,
    );
    expect(
      controller.pagedReaderSettings.singleTapActionAt(0),
      ReaderGestureAction.previousPage,
    );
    expect(
      controller.pagedReaderSettings.singleTapActionAt(5),
      ReaderGestureAction.nextChapter,
    );
    expect(
      controller.pagedReaderSettings.singleTapGridLayout,
      const ReaderGestureGridLayout(
        firstColumnEnd: 0.25,
        secondColumnEnd: 0.7,
        firstRowEnd: 0.2,
        secondRowEnd: 0.75,
      ),
    );
    expect(controller.continuousReaderSettings.crossChapterReading, isFalse);
    expect(controller.continuousReaderSettings.zoomStageFirst, 2.25);
    expect(controller.continuousReaderSettings.longPressZoomScale, 3.0);
    expect(controller.continuousReaderSettings.longPressZoomMoveMode,
        ReaderLongPressMoveMode.focus);

    controller.setReaderModeSettings(
      ReaderMode.continuous,
      controller.continuousReaderSettings.copyWith(
        crossChapterReading: true,
        zoomStages: const <double>[2.5, 4.0],
        singleTapPageAnimation: false,
        singleTapScreenRetainFraction: 0.15,
        singleTapZones: const <ReaderGestureAction>[
          ReaderGestureAction.defaultBehavior,
          ReaderGestureAction.defaultBehavior,
          ReaderGestureAction.defaultBehavior,
          ReaderGestureAction.previousPage,
          ReaderGestureAction.defaultBehavior,
          ReaderGestureAction.nextPage,
          ReaderGestureAction.defaultBehavior,
          ReaderGestureAction.defaultBehavior,
          ReaderGestureAction.defaultBehavior,
        ],
        singleTapGridLayout: const ReaderGestureGridLayout(
          firstColumnEnd: 0.4,
          secondColumnEnd: 0.8,
          firstRowEnd: 0.3,
          secondRowEnd: 0.65,
        ),
      ),
    );
    await controller.flush();

    final modeSettings = written?['readerModeSettings']! as Map;
    final paged = modeSettings['paged']! as Map;
    final continuous = modeSettings['continuous']! as Map;
    expect(paged['crossChapterReading'], isTrue);
    expect(paged['zoomStage1'], 1.75);
    expect(continuous['crossChapterReading'], isTrue);
    expect(continuous['zoomStage1'], 2.5);
    expect(continuous['zoomStage2'], 4.0);
    final gestureActions = continuous['gestureActions']! as Map;
    final singleTap = gestureActions['singleTap']! as Map;
    expect(singleTap['pageAnimation'], isFalse);
    expect(singleTap['screenRetainFraction'], 0.15);
    expect(
      singleTap['zones'],
      <String>[
        'defaultBehavior',
        'defaultBehavior',
        'defaultBehavior',
        'previousPage',
        'defaultBehavior',
        'nextPage',
        'defaultBehavior',
        'defaultBehavior',
        'defaultBehavior',
      ],
    );
    expect(
      singleTap['grid'],
      <String, Object?>{
        'columns': <double>[0.4, 0.8],
        'rows': <double>[0.3, 0.65],
      },
    );
  });

  test('reading defaults match the product baseline', () {
    final controller = AppPreferencesController();
    addTearDown(controller.dispose);
    expect(
      controller.readerPagedDirectionPreference,
      ReaderPagedDirectionPreference.ltr,
    );
    expect(controller.systemStatusBarMode, ReaderSystemStatusBarMode.show);
    expect(controller.pagedReaderSettings.zoomStageFirst, 1.5);
    expect(controller.pagedReaderSettings.zoomStageSecond, 2.0);
    expect(controller.pagedReaderSettings.longPressZoomScale, 2.0);
    expect(
      controller.pagedReaderSettings.doubleTapZoomOrigin,
      ReaderDoubleTapZoomOrigin.center,
    );
    expect(
      controller.pagedReaderSettings.longPressZoomRestoreOnRelease,
      isTrue,
    );
    expect(
      controller.pagedReaderSettings.longPressZoomMoveMode,
      ReaderLongPressMoveMode.drag,
    );
    expect(controller.pagedReaderSettings.longPressZoomPanRatio, 1.0);
    expect(controller.pagedReaderSettings.longPressZoomLimitToViewport, isTrue);
    expect(controller.pagedReaderSettings.crossChapterReading, isFalse);
    expect(controller.continuousReaderSettings.crossChapterReading, isFalse);
    expect(controller.continuousReaderSettings.longPressZoomEnabled, isFalse);
  });

  test('legacy status-bar boolean migrates to the three-state policy',
      () async {
    final hidden = AppPreferencesController();
    addTearDown(hidden.dispose);
    await hidden.attach(
      read: () async => <String, Object?>{'showSystemStatusBar': false},
      write: (_) async {},
    );
    expect(hidden.systemStatusBarMode, ReaderSystemStatusBarMode.hide);

    final shown = AppPreferencesController();
    addTearDown(shown.dispose);
    await shown.attach(
      read: () async => <String, Object?>{'showSystemStatusBar': true},
      write: (_) async {},
    );
    expect(shown.systemStatusBarMode, ReaderSystemStatusBarMode.show);
  });

  test('historical cache conflict trust inherits global unless overridden',
      () async {
    final controller = AppPreferencesController();
    addTearDown(controller.dispose);
    await controller.attach(
      read: () async => null,
      write: (_) async {},
    );

    expect(controller.trustConflictingHistoricalCarriersByDefault, isTrue);
    expect(
      controller.trustConflictingHistoricalCarriersForPlugin('plugin-a'),
      isTrue,
    );
    expect(
      controller.conflictingHistoricalCarrierTrustOverrideForPlugin(
        'plugin-a',
      ),
      isNull,
    );

    controller.setPluginTrustConflictingHistoricalCarriers('plugin-a', false);
    expect(
      controller.trustConflictingHistoricalCarriersForPlugin('plugin-a'),
      isFalse,
    );
    expect(
      controller.conflictingHistoricalCarrierTrustOverrideForPlugin(
        'plugin-a',
      ),
      isFalse,
    );

    controller.clearPluginTrustConflictingHistoricalCarriersOverride(
      'plugin-a',
    );
    expect(
      controller.trustConflictingHistoricalCarriersForPlugin('plugin-a'),
      isTrue,
    );

    controller.setTrustConflictingHistoricalCarriersByDefault(false);
    expect(
      controller.trustConflictingHistoricalCarriersForPlugin('plugin-a'),
      isFalse,
    );
    controller.setPluginTrustConflictingHistoricalCarriers('plugin-a', true);
    expect(
      controller.trustConflictingHistoricalCarriersForPlugin('plugin-a'),
      isTrue,
    );
  });

  test('source trust supersedes and retires legacy plugin trust', () async {
    Map<String, Object?>? written;
    final controller = AppPreferencesController();
    addTearDown(controller.dispose);
    await controller.attach(
      read: () async => <String, Object?>{
        'trustConflictingHistoricalCarriersByDefault': true,
        'pluginTrustConflictingHistoricalCarriers': <String, Object?>{
          'plugin-a': false,
        },
        'sourceTrustConflictingHistoricalCarriers': <String, Object?>{
          'source-explicit': true,
        },
      },
      write: (values) async => written = Map<String, Object?>.from(values),
    );

    expect(
      controller.trustConflictingHistoricalCarriersForSource(
        'source-a',
        legacyPluginId: 'plugin-a',
      ),
      isFalse,
    );
    expect(
      controller.trustConflictingHistoricalCarriersForSource(
        'source-explicit',
        legacyPluginId: 'plugin-a',
      ),
      isTrue,
    );

    controller.migratePluginTrustConflictingHistoricalCarriersToSources(
      'plugin-a',
      const <String>['source-a', 'source-b', 'source-explicit'],
      retirePluginOverride: true,
    );
    expect(
      controller.conflictingHistoricalCarrierTrustOverrideForPlugin('plugin-a'),
      isNull,
    );
    expect(
      controller.conflictingHistoricalCarrierTrustOverrideForSource('source-a'),
      isFalse,
    );
    expect(
      controller.conflictingHistoricalCarrierTrustOverrideForSource(
        'source-b',
      ),
      isFalse,
    );
    expect(
      controller.conflictingHistoricalCarrierTrustOverrideForSource(
        'source-explicit',
      ),
      isTrue,
    );

    controller.clearSourceTrustConflictingHistoricalCarriersOverride(
      'source-a',
    );
    expect(
      controller.trustConflictingHistoricalCarriersForSource(
        'source-a',
        legacyPluginId: 'plugin-a',
      ),
      isTrue,
    );
    await controller.flush();
    expect(
      written?['sourceTrustConflictingHistoricalCarriers'],
      <String, bool>{
        'source-explicit': true,
        'source-b': false,
      },
    );
    expect(
      written?['pluginTrustConflictingHistoricalCarriers'],
      <String, bool>{},
    );
  });

  test('partial source trust migration keeps legacy plugin fallback', () async {
    final controller = AppPreferencesController();
    addTearDown(controller.dispose);
    await controller.attach(
      read: () async => <String, Object?>{
        'pluginTrustConflictingHistoricalCarriers': <String, Object?>{
          'plugin-a': false,
        },
      },
      write: (_) async {},
    );

    controller.migratePluginTrustConflictingHistoricalCarriersToSources(
      'plugin-a',
      const <String>['source-a'],
    );

    expect(
      controller.conflictingHistoricalCarrierTrustOverrideForSource('source-a'),
      isFalse,
    );
    expect(
      controller.conflictingHistoricalCarrierTrustOverrideForPlugin('plugin-a'),
      isFalse,
    );
    expect(
      controller.trustConflictingHistoricalCarriersForSource(
        'source-not-yet-discovered',
        legacyPluginId: 'plugin-a',
      ),
      isFalse,
    );
  });

  test('legacy adaptive-off comic remains an independent adaptive override',
      () async {
    final controller = AppPreferencesController();
    addTearDown(controller.dispose);
    await controller.attach(
      read: () async => <String, Object?>{
        'adaptiveReaderEnabled': true,
        'comicReaderSettings': <String, Object?>{
          comicReaderSettingsIdentity('source', 'comic'): <String, Object?>{
            'enabled': false,
            'adaptiveEnabled': false,
          },
        },
      },
      write: (_) async {},
    );

    final comic = controller.comicReaderSettingsFor('source', 'comic');
    expect(comic.enabled, isFalse);
    expect(comic.adaptiveEnabled, isFalse);
    final session = controller.readerSessionSettingsFor('source', 'comic');
    expect(session.comicSpecificEnabled, isFalse);
    expect(session.effectiveAdaptiveEnabled, isFalse);
    expect(session.directionOverride, isNull);
  });

  test('legacy vertical long-press setting migrates to generic override', () {
    final settings = ComicReaderSettings.fromJson(
      <String, Object?>{'verticalLongPressZoom': true},
    );

    expect(settings.longPressZoomOverride, isTrue);
    expect(settings.toJson()['longPressZoomOverride'], isTrue);
    expect(settings.toJson().containsKey('verticalLongPressZoom'), isFalse);
  });

  test('legacy per-comic stitch false inherits the global setting', () async {
    final controller = AppPreferencesController();
    addTearDown(controller.dispose);

    await controller.attach(
      read: () async => <String, Object?>{
        'defaultVerticalStitch': true,
        'comicReaderSettings': <String, Object?>{
          comicReaderSettingsIdentity('source', 'comic'): <String, Object?>{
            'enabled': true,
            'directionOverride': 'vertical',
            'verticalStitch': false,
          },
        },
      },
      write: (_) async {},
    );

    final comic = controller.comicReaderSettingsFor('source', 'comic');
    expect(comic.verticalStitchOverride, isNull);
    expect(
      controller.readerSessionSettingsFor('source', 'comic')
          .effectiveVerticalStitch,
      isTrue,
    );
  });

  test('library backup preserves the complete metadata sections', () async {
    final store = MemoryImportedLibraryStore();
    addTearDown(store.close);
    await store.open();

    final backup = await buildImportedLibraryBackup(store);

    expect(backup['format'], 'zic-library-backup-v1');
    expect(backup['chapters'], isEmpty);
    expect(backup['savedComics'], isEmpty);
    expect(backup['categories'], isEmpty);
    expect(backup['comicPreferences'], isEmpty);
    expect(backup['chapterReadStates'], isEmpty);
    expect(backup['sourcePreferences'], isEmpty);
    expect(backup['migrationIssues'], isEmpty);
  });

  test('library backup prefers one store-owned semantic snapshot', () async {
    final store = _SnapshotOnlyImportedLibraryStore();

    final backup = await buildImportedLibraryBackup(store);

    expect(store.snapshotReads, 1);
    expect(backup['format'], 'zic-library-backup-v1');
    expect(backup['chapters'], isEmpty);
  });

  test('startup preference read cannot overwrite a newer user choice', () async {
    final controller = AppPreferencesController();
    addTearDown(controller.dispose);
    final read = Completer<Map<String, Object?>?>();
    Map<String, Object?>? written;

    final attach = controller.attach(
      read: () => read.future,
      write: (values) async => written = Map<String, Object?>.from(values),
    );
    controller.setThemeMode(ThemeMode.light);
    read.complete(<String, Object?>{'themeMode': 'dark'});
    await attach;

    expect(controller.themeMode, ThemeMode.light);
    expect(written?['themeMode'], 'light');
  });

  test('missing startup preferences stay in memory until user change', () async {
    final controller = AppPreferencesController();
    addTearDown(controller.dispose);
    var writes = 0;

    await controller.attach(
      read: () async => null,
      write: (_) async => writes++,
    );

    expect(writes, 0);
    controller.setThemeMode(ThemeMode.light);
    await controller.flush();
    expect(writes, 1);
  });

  test('debug trace projection is bounded and can be disabled', () {
    final log = DebugTraceLog(maxEvents: 2);
    addTearDown(log.dispose);
    for (var index = 0; index < 3; index++) {
      log.record(
        TraceEvent(
          monotonicMicros: index,
          sessionId: 'test',
          kind: TraceEventKind.downloadState,
          payload: <String, Object?>{'index': index},
        ),
      );
    }

    expect(log.events, hasLength(2));
    expect(log.events.first.payload['index'], 1);
    log.enabled = false;
    log.record(
      TraceEvent(
        monotonicMicros: 4,
        sessionId: 'test',
        kind: TraceEventKind.taskFailed,
      ),
    );
    expect(log.events, hasLength(2));
  });
  test('debug trace keeps a separate bounded diagnostic export ring', () {
    final log = DebugTraceLog(maxEvents: 1, maxExportEvents: 3);
    addTearDown(log.dispose);
    for (var index = 0; index < 5; index++) {
      log.record(
        TraceEvent(
          monotonicMicros: index,
          sessionId: index < 2 ? 'old' : 'reader',
          kind: TraceEventKind.downloadState,
          payload: <String, Object?>{'index': index},
        ),
      );
    }

    expect(log.events, hasLength(1));
    expect(log.exportEventCount, 3);
    expect(log.exportEvents, hasLength(3));
    expect(log.exportEvents.map((event) => event.payload['index']), <int>[2, 3, 4]);
    expect(log.exportDroppedCount, 2);
    expect(log.sessionIds, <String>{'reader'});
    log.clear();
    expect(log.exportEventCount, 0);
    expect(log.exportEvents, isEmpty);
    expect(log.exportDroppedCount, 0);
  });

  test('debug trace forgets coalescing buckets when their event is evicted', () {
    final log = DebugTraceLog(maxEvents: 1, maxExportEvents: 2);
    addTearDown(log.dispose);
    TraceEvent observation(int micros) => TraceEvent(
          monotonicMicros: micros,
          sessionId: 'reader-ring',
          kind: TraceEventKind.readerObservation,
          payload: const <String, Object?>{
            'currentIndex': 1,
            'targetIndex': 2,
            'interaction': 'scrolling',
          },
        );

    log.record(observation(0));
    for (var index = 1; index <= 2; index++) {
      log.record(
        TraceEvent(
          monotonicMicros: index,
          sessionId: 'reader-ring',
          kind: TraceEventKind.downloadState,
          payload: <String, Object?>{'index': index},
        ),
      );
    }
    log.record(observation(100000));

    expect(log.exportCoalescedCount, 0);
    expect(log.exportDroppedCount, 2);
    expect(
      log.exportEvents.map((event) => event.kind),
      <TraceEventKind>[
        TraceEventKind.downloadState,
        TraceEventKind.readerObservation,
      ],
    );
  });

  test('debug trace keeps reader lifecycle stages in separate export buckets', () {
    final log = DebugTraceLog(maxEvents: 4, maxExportEvents: 8);
    addTearDown(log.dispose);
    log.record(
      TraceEvent(
        monotonicMicros: 1000,
        sessionId: 'reader-entry',
        kind: TraceEventKind.readerObservation,
        payload: const <String, Object?>{'stage': 'reader-prepare-start'},
      ),
    );
    log.record(
      TraceEvent(
        monotonicMicros: 2000,
        sessionId: 'reader-entry',
        kind: TraceEventKind.readerObservation,
        payload: const <String, Object?>{'stage': 'reader-prepare-complete'},
      ),
    );

    expect(log.exportEvents, hasLength(2));
    expect(
      log.exportEvents.map((event) => event.payload['stage']),
      <Object?>['reader-prepare-start', 'reader-prepare-complete'],
    );
  });

  testWidgets('debug trace copy uses the diagnostic export ring', (tester) async {
    final log = DebugTraceLog(maxEvents: 1, maxExportEvents: 10);
    addTearDown(log.dispose);
    for (var index = 0; index < 3; index++) {
      log.record(
        TraceEvent(
          monotonicMicros: index,
          sessionId: 'reader-copy',
          kind: TraceEventKind.downloadState,
          payload: <String, Object?>{'index': index},
        ),
      );
    }
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final arguments = Map<String, Object?>.from(call.arguments as Map);
          copied = arguments['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(MaterialApp(home: DebugTraceScreen(log: log)));
    await tester.pump();
    await tester.tap(find.byKey(debugTraceCopyKey));
    await tester.pump();

    expect(copied, isNotNull);
    expect(copied!.split('\n'), hasLength(3));
    expect(copied, contains('\"index\":0'));
    expect(copied, contains('\"index\":2'));
  });

  testWidgets('debug trace copy is bounded by UTF-8 bytes', (tester) async {
    final log = DebugTraceLog(maxEvents: 1, maxExportEvents: 2000);
    addTearDown(log.dispose);
    for (var index = 0; index < 1000; index++) {
      log.record(
        TraceEvent(
          monotonicMicros: index,
          sessionId: 'reader-large-copy',
          kind: TraceEventKind.downloadState,
          payload: <String, Object?>{
            'index': index,
            'detail': List<String>.filled(40, '像素对齐').join(),
          },
        ),
      );
    }
    String? copied;
    await tester.pumpWidget(
      MaterialApp(
        home: DebugTraceScreen(
          log: log,
          writeClipboard: (text) async => copied = text,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(debugTraceCopyKey));
    await tester.pump();

    expect(copied, isNotNull);
    expect(utf8.encode(copied!).length, lessThanOrEqualTo(debugTraceClipboardMaxBytes));
    expect(find.textContaining('剪贴板上限'), findsOneWidget);
  });

  testWidgets('debug trace copy reports platform failure', (tester) async {
    final log = DebugTraceLog(maxEvents: 2, maxExportEvents: 2);
    addTearDown(log.dispose);
    log.record(
      TraceEvent(
        monotonicMicros: 1,
        sessionId: 'reader-copy-failure',
        kind: TraceEventKind.downloadState,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DebugTraceScreen(
          log: log,
          writeClipboard: (_) async => throw StateError('clipboard unavailable'),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(debugTraceCopyKey));
    await tester.pump();

    expect(find.textContaining('Trace 复制失败'), findsOneWidget);
  });

  testWidgets('debug trace file export uses the diagnostic export ring',
      (tester) async {
    final log = DebugTraceLog(maxEvents: 1, maxExportEvents: 10);
    addTearDown(log.dispose);
    for (var index = 0; index < 3; index++) {
      log.record(
        TraceEvent(
          monotonicMicros: index,
          sessionId: 'reader-export',
          kind: TraceEventKind.downloadState,
          payload: <String, Object?>{'index': index},
        ),
      );
    }
    Uint8List? exported;
    await tester.pumpWidget(
      MaterialApp(
        home: DebugTraceScreen(
          log: log,
          exportDirectory: 'Debug',
          exportEvents: (events) => exportDebugTraceEvents(
            events: events,
            relativeDirectory: 'Debug',
            writeFile: ({
              required String suggestedName,
              required Uint8List bytes,
              required String relativeDirectory,
            }) async {
              expect(suggestedName, endsWith('.jsonl'));
              expect(relativeDirectory, 'Debug');
              exported = bytes;
              return '/tmp/$suggestedName';
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(debugTraceExportKey));
    await tester.pump();
    await tester.pump();

    final text = utf8.decode(exported!);
    expect(text.split('\n'), hasLength(3));
    expect(text, contains('\"index\":0'));
    expect(text, contains('\"index\":2'));
    expect(
      find.text('已导出 3 条诊断 Trace 到 Download/Debug'),
      findsOneWidget,
    );
  });

  testWidgets('debug trace export directory dialog keeps input alive through close',
      (tester) async {
    final log = DebugTraceLog(maxEvents: 1);
    addTearDown(log.dispose);
    String? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: DebugTraceScreen(
          log: log,
          exportDirectory: 'Debug',
          onExportDirectoryChanged: (value) => changed = value,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(debugTraceExportDirectoryKey));
    await tester.pumpAndSettle();
    expect(find.text('Trace 导出目录'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField), 'Debug/Reader');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(changed, 'Debug/Reader');
    expect(find.text('导出目录 Download/Debug/Reader'), findsOneWidget);
  });

  testWidgets('debug trace export gives immediate busy feedback and is single-flight',
      (tester) async {
    final log = DebugTraceLog(maxEvents: 1, maxExportEvents: 10);
    addTearDown(log.dispose);
    log.record(
      TraceEvent(
        monotonicMicros: 1,
        sessionId: 'reader-export-busy',
        kind: TraceEventKind.downloadState,
      ),
    );
    final release = Completer<DebugTraceExportResult?>();
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DebugTraceScreen(
          log: log,
          exportEvents: (events) {
            calls++;
            return release.future;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(debugTraceExportKey));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(calls, 1);
    await tester.tap(find.byKey(debugTraceExportKey), warnIfMissed: false);
    await tester.pump();
    expect(calls, 1);

    release.complete(
      const DebugTraceExportResult(
        path: '/tmp/zic-debug-trace.jsonl',
        eventCount: 1,
        relativeDirectory: 'Debug',
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  test('debug trace folds high-frequency export samples but preserves errors', () {
    final log = DebugTraceLog(maxEvents: 4, maxExportEvents: 20);
    addTearDown(log.dispose);
    for (var index = 0; index < 8; index++) {
      log.record(
        TraceEvent(
          monotonicMicros: index * 100000,
          sessionId: 'reader-export-fold',
          kind: TraceEventKind.framePresented,
          identityHash: 'page-a',
          payload: <String, Object?>{
            'frame': index,
            'presentMicros': 100 + index,
          },
        ),
      );
    }
    log.record(
      TraceEvent(
        monotonicMicros: 900000,
        sessionId: 'reader-export-fold',
        kind: TraceEventKind.taskFailed,
        payload: <String, Object?>{'reason': 'fixture'},
      ),
    );

    expect(log.exportEvents, hasLength(2));
    expect(log.exportCoalescedCount, 7);
    final folded = log.exportEvents.first;
    expect(folded.payload['coalescedCount'], 8);
    expect(folded.payload['firstFrameIndex'], 0);
    expect(folded.payload['lastFrameIndex'], 7);
    expect(folded.payload['minPresentMicros'], 100);
    expect(folded.payload['maxPresentMicros'], 107);
    expect(log.exportEvents.last.kind, TraceEventKind.taskFailed);
  });

  test('frame pipeline timing export folds only matching semantic buckets', () {
    final log = DebugTraceLog(maxEvents: 4);
    addTearDown(log.dispose);
    for (var index = 0; index < 3; index++) {
      log.record(
        TraceEvent(
          monotonicMicros: index * 100000,
          sessionId: 'frame-pipeline',
          kind: TraceEventKind.framePipelineTiming,
          identityHash: 'page-a',
          payload: <String, Object?>{
            'frame': index,
            'traceReason': 'startup',
            'dominantStage': 'nativeDecode',
            'role': 'current',
            'decodedRole': 'current',
            'uploadRole': 'current',
            'sourceLength': 1000 + index * 100,
            'nativeDecodeMicros': 100 + index,
            'decodedLeadMicros': 150 + index,
            'uploadBackpressureMicros': 175 + index,
            'platformResultDispatchMicros': 200 + index,
          },
        ),
      );
    }
    log.record(
      TraceEvent(
        monotonicMicros: 250000,
        sessionId: 'frame-pipeline',
        kind: TraceEventKind.framePipelineTiming,
        identityHash: 'page-a',
        payload: <String, Object?>{
          'frame': 3,
          'traceReason': 'stall',
          'dominantStage': 'sourceWait',
          'role': 'current',
          'decodedRole': 'current',
          'uploadRole': 'current',
          'sourceLength': 1300,
          'sourceWaitMicros': 9000,
        },
      ),
    );

    expect(log.exportEvents, hasLength(2));
    expect(log.exportCoalescedCount, 2);
    final folded = log.exportEvents.first;
    expect(folded.payload['coalescedCount'], 3);
    expect(folded.payload['firstFrameIndex'], 0);
    expect(folded.payload['lastFrameIndex'], 2);
    expect(folded.payload['minSourceLength'], 1000);
    expect(folded.payload['maxSourceLength'], 1200);
    expect(folded.payload['minNativeDecodeMicros'], 100);
    expect(folded.payload['maxNativeDecodeMicros'], 102);
    expect(log.exportEvents.last.payload['dominantStage'], 'sourceWait');
  });

  test('reader frame timing folds healthy cadence but keeps jank boundaries', () {
    final log = DebugTraceLog(maxEvents: 8, maxExportEvents: 8);
    addTearDown(log.dispose);

    TraceEvent timing(
      int micros, {
      int buildMicros = 3000,
      int frameIntervalMicros = 16667,
    }) => TraceEvent(
          monotonicMicros: micros,
          sessionId: 'reader-cadence',
          kind: TraceEventKind.readerFrameTiming,
          payload: <String, Object?>{
            'buildMicros': buildMicros,
            'rasterMicros': 2500,
            'totalSpanMicros': 6000,
            'vsyncOverheadMicros': 400,
            'vsyncStartMicros': micros,
            'frameIntervalMicros': frameIntervalMicros,
          },
        );

    log.record(timing(0));
    log.record(timing(100000));
    log.record(timing(200000, buildMicros: 20000));
    log.record(timing(300000));

    expect(log.exportEvents, hasLength(3));
    expect(log.exportCoalescedCount, 1);
    expect(log.exportEvents[0].payload['coalescedCount'], 2);
    expect(log.exportEvents[1].payload['buildMicros'], 20000);
    expect(log.exportEvents[2].payload['coalescedCount'], isNull);
    expect(log.events, hasLength(1));
    expect(log.events.single.payload['buildMicros'], 20000);
  });

  test('reader frame timing retains interval jank as an independent sample', () {
    final log = DebugTraceLog(maxEvents: 8, maxExportEvents: 8);
    addTearDown(log.dispose);

    TraceEvent timing(int micros, int interval) => TraceEvent(
          monotonicMicros: micros,
          sessionId: 'reader-interval',
          kind: TraceEventKind.readerFrameTiming,
          payload: <String, Object?>{
            'buildMicros': 3000,
            'rasterMicros': 2500,
            'totalSpanMicros': 6000,
            'vsyncOverheadMicros': 400,
            'vsyncStartMicros': micros,
            'frameIntervalMicros': interval,
          },
        );

    log.record(timing(0, 16667));
    log.record(timing(100000, 25000));
    log.record(timing(200000, 16667));

    expect(log.exportEvents, hasLength(3));
    expect(log.exportEvents[1].payload['frameIntervalMicros'], 25000);
    expect(log.events, hasLength(1));
    expect(log.events.single.payload['frameIntervalMicros'], 25000);
  });

  test('decode refill export folds same role stage and source-wake bucket', () {
    final log = DebugTraceLog(maxEvents: 4);
    addTearDown(log.dispose);
    for (var index = 0; index < 3; index++) {
      log.record(
        TraceEvent(
          monotonicMicros: index * 100000,
          sessionId: 'decode-refill',
          kind: TraceEventKind.decodeRefill,
          identityHash: 'page-a',
          payload: <String, Object?>{
            'role': 'current',
            'stage': 'one>0',
            'sourceWake': true,
            'sourceRevision': index + 1,
            'consumedSourceRevision': index,
            'depth': 0,
            'target': 1,
          },
        ),
      );
    }
    log.record(
      TraceEvent(
        monotonicMicros: 250000,
        sessionId: 'decode-refill',
        kind: TraceEventKind.decodeRefill,
        identityHash: 'page-a',
        payload: <String, Object?>{
          'role': 'current',
          'stage': 'one>0',
          'sourceWake': false,
          'sourceRevision': 4,
          'consumedSourceRevision': 3,
          'depth': 0,
          'target': 1,
        },
      ),
    );

    expect(log.exportEvents, hasLength(2));
    expect(log.exportCoalescedCount, 2);
    final folded = log.exportEvents.first;
    expect(folded.payload['coalescedCount'], 3);
    expect(folded.payload['minSourceRevision'], 1);
    expect(folded.payload['maxSourceRevision'], 3);
    expect(folded.payload['minConsumedSourceRevision'], 0);
    expect(folded.payload['maxConsumedSourceRevision'], 2);
    expect(log.exportEvents.last.payload['sourceWake'], isFalse);
  });

  testWidgets('debug trace notifications are deferred past build',
      (tester) async {
    final log = DebugTraceLog(maxEvents: 4);
    addTearDown(log.dispose);
    var notifications = 0;
    var notifiedDuringBuild = false;
    var recorded = false;
    log.addListener(() {
      notifications++;
      if (SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        notifiedDuringBuild = true;
      }
    });

    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: log,
          builder: (context, _) {
            if (!recorded) {
              recorded = true;
              log.record(
                TraceEvent(
                  monotonicMicros: 1,
                  sessionId: 'build',
                  kind: TraceEventKind.pageHostMounted,
                ),
              );
            }
            return Text('${log.events.length}');
          },
        ),
      ),
    );

    expect(notifiedDuringBuild, isFalse);
    expect(notifications, 1);
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('debug trace without a viewer does not request a Flutter frame',
      (tester) async {
    final log = DebugTraceLog(maxEvents: 4);
    addTearDown(log.dispose);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);

    log.record(
      TraceEvent(
        monotonicMicros: 1,
        sessionId: 'headless-trace',
        kind: TraceEventKind.downloadState,
      ),
    );

    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets(
      'debug trace media frame events do not request a diagnostic Flutter frame',
      (tester) async {
    final log = DebugTraceLog(maxEvents: 4);
    addTearDown(log.dispose);
    log.addListener(() {});
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);

    log.record(
      TraceEvent(
        monotonicMicros: 1,
        sessionId: 'animated-reader',
        kind: TraceEventKind.framePresented,
        payload: const <String, Object?>{'frame': 1},
      ),
    );

    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(log.exportEvents, hasLength(1));
  });

  test('debug trace coalesces lifecycle bursts but preserves failures', () {
    final log = DebugTraceLog(maxEvents: 20);
    addTearDown(log.dispose);
    for (var index = 0; index < 12; index++) {
      log.record(
        TraceEvent(
          monotonicMicros: index * 1000,
          sessionId: 'reader',
          kind: TraceEventKind.pageHostMounted,
          payload: <String, Object?>{'pageIndex': index},
        ),
      );
    }
    log.record(
      TraceEvent(
        monotonicMicros: 13000,
        sessionId: 'reader',
        kind: TraceEventKind.taskFailed,
      ),
    );

    expect(log.recordedCount, 13);
    expect(log.events, hasLength(2));
    expect(log.events.first.payload['coalescedCount'], 12);
    expect(log.events.first.payload['firstPageIndex'], 0);
    expect(log.events.first.payload['lastPageIndex'], 11);
    expect(log.events.last.kind, TraceEventKind.taskFailed);
  });

  testWidgets('debug trace screen exposes export and filters', (tester) async {
    final log = DebugTraceLog(maxEvents: 20);
    addTearDown(log.dispose);
    log.record(
      TraceEvent(
        monotonicMicros: 1,
        sessionId: 'reader-a',
        kind: TraceEventKind.taskFailed,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(home: DebugTraceScreen(log: log)),
    );
    await tester.pump();

    expect(find.byKey(debugTraceExportKey), findsOneWidget);
    expect(find.byKey(debugTraceSearchKey), findsOneWidget);
    expect(find.byKey(debugTraceSessionFilterKey), findsOneWidget);
    expect(find.byKey(debugTraceLevelFilterKey), findsOneWidget);
    expect(find.text('taskFailed'), findsOneWidget);
  });

}

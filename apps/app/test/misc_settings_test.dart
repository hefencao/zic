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
import 'package:telemetry/telemetry.dart';
import 'package:zic/app_preferences.dart';
import 'package:zic/app_settings_screen.dart';
import 'package:zic/debug_trace.dart';
import 'package:zic/debug_trace_export.dart';
import 'package:zic/debug_trace_screen.dart';
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

    await tester.tap(find.byKey(settingsDataEntryKey));
    await tester.pump();
    await _pumpUntilFound(tester, find.byKey(dataSettingsScreenKey));
    expect(find.byKey(dataFileAccessSettingsKey), findsOneWidget);
    expect(find.text('文件读写设置'), findsOneWidget);
    expect(find.textContaining('所有文件访问'), findsOneWidget);
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
        'debugTraceEnabled': false,
        'shelfSourceFilter': 'remote',
        'shelfSortMode': 'title',
        'shelfView': 'list',
        'defaultReaderMode': 'continuous',
        'readerStartsImmersive': false,
        'adaptiveReaderEnabled': true,
        'defaultVerticalStitch': true,
        'defaultZoomStage1': 3.0,
        'defaultZoomStage2': 5.0,
        'longPressZoomEnabled': false,
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
    expect(controller.debugTraceEnabled, isFalse);
    expect(controller.shelfSourceFilter, ShelfSourceFilter.remote);
    expect(controller.shelfSortMode, LibrarySortMode.title);
    expect(controller.shelfView, ShelfViewPreference.list);
    expect(controller.defaultReaderMode, ReaderMode.continuous);
    expect(controller.readerStartsImmersive, isFalse);
    expect(controller.adaptiveReaderEnabled, isTrue);
    expect(controller.defaultVerticalStitch, isTrue);
    expect(controller.defaultZoomStageFirst, 3.0);
    expect(controller.defaultZoomStageSecond, 5.0);
    expect(controller.longPressZoomEnabled, isFalse);
    expect(controller.longPressZoomRestoreOnRelease, isFalse);
    expect(
      controller.longPressZoomMoveMode,
      ReaderLongPressMoveMode.focus,
    );
    expect(controller.longPressZoomPanRatio, 1.5);
    expect(controller.longPressZoomLimitToViewport, isFalse);
    expect(controller.doubleTapZoomOrigin, ReaderDoubleTapZoomOrigin.snap);
    expect(controller.zoomDecodeBoostEnabled, isFalse);
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
    controller.setShelfSortMode(LibrarySortMode.custom);
    controller.setDetailsPreviewMaxItemsPerRow(4);
    controller.setNetworkUserAgent('custom-network-agent');
    controller.setDebugTraceExportDirectory('Debug/Reader');
    controller.setChapterDownloadDirectoryOverride('/data/downloads');
    controller.setChapterDownloadDirectoryPendingMoveFrom('/data/old');
    controller.setCacheLimitMb(1024);
    controller.setReaderPrefetchReadBudgetMiB(64);
    controller.setCachedCarrierTrustMode(CachedCarrierTrustMode.trustCached);
    controller.setPluginTrustConflictingHistoricalCarriers(
      'mihon:fixture-plugin',
      true,
    );
    controller.setSourceDownloadDirectory('venera:gamma', '/data/gamma');
    controller.setLongPressZoomRestoreOnRelease(true);
    controller.setLongPressZoomMoveMode(ReaderLongPressMoveMode.drag);
    controller.setLongPressZoomPanRatio(2.0);
    controller.setLongPressZoomLimitToViewport(true);
    controller.setDoubleTapZoomOrigin(ReaderDoubleTapZoomOrigin.focus);
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
    expect(written?['shelfSortMode'], 'custom');
    expect(written?['version'], 7);
    expect(written?['detailsPreviewMaxItemsPerRow'], 4);
    expect(written?['networkUserAgent'], 'custom-network-agent');
    expect(written?['debugTraceExportDirectory'], 'Debug/Reader');
    expect(written?['chapterDownloadDirectoryOverride'], '/data/downloads');
    expect(
      written?['chapterDownloadDirectoryPendingMoveFrom'],
      '/data/old',
    );
    expect(written?['cacheLimitMb'], 1024);
    expect(written?['readerPrefetchReadBudgetMiB'], 64);
    expect(written?['cachedCarrierTrustMode'], 'trustCached');
    expect(
      written?['pluginTrustConflictingHistoricalCarriers'],
      <String, bool>{
        'venera:fixture-plugin': true,
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
    expect(written?['longPressZoomRestoreOnRelease'], true);
    expect(written?['longPressZoomMoveMode'], 'drag');
    expect(written?['longPressZoomPanRatio'], 2.0);
    expect(written?['longPressZoomLimitToViewport'], true);
    expect(written?['doubleTapZoomOrigin'], 'focus');
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

  test('reading zoom defaults match the product baseline', () {
    final controller = AppPreferencesController();
    addTearDown(controller.dispose);
    expect(controller.defaultZoomStageFirst, 1.5);
    expect(controller.defaultZoomStageSecond, 2.0);
    expect(
      controller.doubleTapZoomOrigin,
      ReaderDoubleTapZoomOrigin.center,
    );
    expect(controller.longPressZoomRestoreOnRelease, isTrue);
    expect(
      controller.longPressZoomMoveMode,
      ReaderLongPressMoveMode.drag,
    );
    expect(controller.longPressZoomPanRatio, 1.0);
    expect(controller.longPressZoomLimitToViewport, isTrue);
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

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_runtime/reader_runtime.dart';
import 'package:telemetry/telemetry.dart';
import 'package:zic/app_preferences.dart';
import 'package:zic/app_settings_screen.dart';
import 'package:zic/debug_trace.dart';
import 'package:zic/debug_trace_screen.dart';
import 'package:zic/library_backup.dart';
import 'package:zic/main.dart';
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
  });

  test('application preferences load and persist through injected storage', () async {
    final controller = AppPreferencesController();
    addTearDown(controller.dispose);
    Map<String, Object?>? written;

    await controller.attach(
      read: () async => <String, Object?>{
        'themeMode': 'light',
        'debugTraceEnabled': false,
        'shelfSourceFilter': 'remote',
        'shelfSortMode': 'title',
        'shelfView': 'list',
        'defaultReaderMode': 'continuous',
        'readerStartsImmersive': false,
        'adaptiveReaderEnabled': true,
        'defaultVerticalStitch': true,
        'detailsPreviewMaxItemsPerRow': 6,
        'networkUserAgent': 'fixture-network-agent',
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
    expect(controller.debugTraceEnabled, isFalse);
    expect(controller.shelfSourceFilter, ShelfSourceFilter.remote);
    expect(controller.shelfSortMode, LibrarySortMode.title);
    expect(controller.shelfView, ShelfViewPreference.list);
    expect(controller.defaultReaderMode, ReaderMode.continuous);
    expect(controller.readerStartsImmersive, isFalse);
    expect(controller.adaptiveReaderEnabled, isTrue);
    expect(controller.defaultVerticalStitch, isTrue);
    expect(controller.detailsPreviewMaxItemsPerRow, 6);
    expect(controller.networkUserAgent, 'fixture-network-agent');
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
    controller.setShelfSortMode(LibrarySortMode.custom);
    controller.setDetailsPreviewMaxItemsPerRow(4);
    controller.setNetworkUserAgent('custom-network-agent');
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
    expect(written?['shelfSortMode'], 'custom');
    expect(written?['version'], 6);
    expect(written?['detailsPreviewMaxItemsPerRow'], 4);
    expect(written?['networkUserAgent'], 'custom-network-agent');
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
    expect(log.exportEvents, hasLength(3));
    expect(log.exportEvents.map((event) => event.payload['index']), <int>[2, 3, 4]);
    expect(log.exportDroppedCount, 2);
    expect(log.sessionIds, <String>{'reader'});
    log.clear();
    expect(log.exportEvents, isEmpty);
    expect(log.exportDroppedCount, 0);
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
          exportFile: ({
            required String suggestedName,
            required Uint8List bytes,
          }) async {
            expect(suggestedName, endsWith('.jsonl'));
            exported = bytes;
            return '/tmp/$suggestedName';
          },
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(debugTraceExportKey));
    await tester.pump();

    final text = utf8.decode(exported!);
    expect(text.split('\n'), hasLength(3));
    expect(text, contains('\"index\":0'));
    expect(text, contains('\"index\":2'));
    expect(find.text('已导出 3 条诊断 Trace'), findsOneWidget);
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

  test('frame pipeline timing remains exact in export', () {
    final log = DebugTraceLog(maxEvents: 4);
    addTearDown(log.dispose);
    for (var index = 0; index < 3; index++) {
      log.record(
        TraceEvent(
          monotonicMicros: index * 1000,
          sessionId: 'frame-pipeline',
          kind: TraceEventKind.framePipelineTiming,
          payload: <String, Object?>{
            'frame': index,
            'presentationOrdinal': index,
            'nativeDecodeMicros': 100 + index,
            'decodedLeadMicros': 150 + index,
            'uploadBackpressureMicros': 175 + index,
            'platformResultDispatchMicros': 200 + index,
          },
        ),
      );
    }

    expect(log.exportEvents, hasLength(3));
    expect(log.exportCoalescedCount, 0);
    expect(
      log.exportEvents.map((event) => event.payload['frame']),
      <Object?>[0, 1, 2],
    );
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

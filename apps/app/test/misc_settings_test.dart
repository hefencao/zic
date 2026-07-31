import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry/telemetry.dart';
import 'package:zic/app_preferences.dart';
import 'package:zic/app_settings_screen.dart';
import 'package:zic/debug_trace.dart';
import 'package:zic/library_backup.dart';
import 'package:zic/main.dart';
import 'package:zic/misc_page.dart';

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

    controller.setThemeMode(ThemeMode.dark);
    controller.setShelfSortMode(LibrarySortMode.custom);
    await controller.flush();

    expect(written?['themeMode'], 'dark');
    expect(written?['shelfSortMode'], 'custom');
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
}

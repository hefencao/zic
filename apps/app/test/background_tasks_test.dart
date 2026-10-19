import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:comic_translation/comic_translation.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry/telemetry.dart';
import 'package:zic/background_tasks.dart';
import 'package:zic/background_tasks_platform.dart';
import 'package:zic/download_command_lifetimes.dart';
import 'package:zic/translation_chapter_jobs.dart';

void main() {
  test('slow command preparation starts protection before a service exists', () async {
    final commands = DownloadCommandLifetimes();
    final preparation = Completer<void>();
    final jobs = AppTranslationChapterJobs();
    final platform = _Platform();
    final controller = AppBackgroundTasks(translations: jobs, platform: platform,
      commands: commands, engines: ComicTranslationEngineRegistry());
    var transferred = false;
    final work = commands.run((command) async {
      await preparation.future;
      command.check();
      transferred = true;
    });
    final failed = expectLater(work, throwsA(isA<Failure>()));
    await _flush();
    expect(platform.states.last['active'], true);
    expect(platform.states.last['preparing'], 1);
    controller.setLifecycle(AppLifecycleState.paused);
    final stopping = platform.action!('stop');
    await _flush();
    expect(platform.states.last['stopping'], true);
    preparation.complete();
    await Future.wait([stopping, failed]);
    await _flush();
    expect(transferred, false);
    expect(platform.states.last['active'], false);
    await controller.close();
    commands.dispose();
    jobs.dispose();
  });

  test('notification remains through physical download cancellation drain', () async {
    final downloads = _Downloads();
    final jobs = AppTranslationChapterJobs();
    final platform = _Platform();
    final controller = AppBackgroundTasks(translations: jobs, platform: platform,
      engines: ComicTranslationEngineRegistry());
    controller.bind(downloads: downloads);
    downloads.entries.add(_entry);
    downloads.execution.add(null);
    await _flush();
    expect(platform.states.last['active'], true);
    expect(platform.states.last['downloads'], 1);
    final stopping = platform.action!('stop');
    await _flush();
    expect(downloads.cancelled, [_entry]);
    expect(platform.states.last['active'], true);
    expect(platform.states.last['stopping'], true);
    downloads.drained.complete();
    await stopping;
    await _flush();
    expect(platform.states.last['active'], false);
    await controller.close();
    await downloads.close();
    jobs.dispose();
  });

  for (final granted in [true, false]) {
    test('background chapter permission requires service acknowledgement $granted', () async {
      final initialized = Completer<void>();
      final jobs = AppTranslationChapterJobs(initialize: () => initialized.future);
      final engines = ComicTranslationEngineRegistry();
      final platform = _Platform(granted: granted);
      final controller = AppBackgroundTasks(translations: jobs, engines: engines, platform: platform);
      final completion = jobs.start(_entry, trace: const NoopTraceSink(),
        prepare: () async => (entry: _entry, composition: null));
      await _flush();
      controller.setLifecycle(AppLifecycleState.paused);
      await _flush();
      expect(engines.workPaused.value, true, reason: 'Reader must stay paused');
      expect(engines.pauseState(backgroundExecution: true).value, !granted);
      final stopping = platform.action!('timeout');
      await _flush();
      expect(engines.pauseState(backgroundExecution: true).value, true);
      expect(platform.states.last['active'], false, reason: 'timeout must not relaunch the service');
      initialized.complete();
      await Future.wait([stopping, completion]);
      await controller.close();
      jobs.dispose();
    });
  }

  test('late service acknowledgement cannot undo a timeout', () async {
    final initialized = Completer<void>();
    final ack = Completer<bool>();
    final jobs = AppTranslationChapterJobs(initialize: () => initialized.future);
    final engines = ComicTranslationEngineRegistry();
    final platform = _Platform()..nextAck = ack.future;
    final controller = AppBackgroundTasks(translations: jobs, engines: engines, platform: platform);
    final completion = jobs.start(_entry, trace: const NoopTraceSink(),
      prepare: () async => (entry: _entry, composition: null));
    controller.setLifecycle(AppLifecycleState.paused);
    final stopping = platform.action!('interrupted');
    ack.complete(true);
    await _flush();
    expect(engines.pauseState(backgroundExecution: true).value, true);
    expect(platform.states.last['active'], false);
    initialized.complete();
    await Future.wait([stopping, completion]);
    await controller.close();
    jobs.dispose();
  });

  test('Reader cache publications do not start a background task', () async {
    final downloads = _Downloads();
    final jobs = AppTranslationChapterJobs();
    final platform = _Platform();
    final controller = AppBackgroundTasks(translations: jobs, platform: platform,
      engines: ComicTranslationEngineRegistry());
    controller.bind(downloads: downloads);
    downloads.progress.add(ChapterDownloadSnapshot.idle(_entry));
    await _flush();
    expect(platform.states.every((state) => state['active'] == false), true);
    await controller.close();
    await downloads.close();
    jobs.dispose();
  });
}

Future<void> _flush() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final class _Platform implements BackgroundTasksPlatform {
  _Platform({this.granted = true});
  final bool granted;
  Future<bool>? nextAck;
  final List<Map<String, Object>> states = [];
  Future<void> Function(String)? action;
  @override
  bool get supported => true;
  @override
  void setActionHandler(Future<void> Function(String action)? handler) => action = handler;
  @override
  Future<bool> update(Map<String, Object> state) async {
    states.add(Map.of(state));
    final ack = nextAck;
    nextAck = null;
    return ack != null ? await ack : granted;
  }
}

final class _Downloads extends Fake implements ChapterDownloadService, ChapterDownloadExecutionSource {
  final List<ImportedLibraryEntry> entries = [];
  final List<ImportedLibraryEntry> cancelled = [];
  final execution = StreamController<void>.broadcast(sync: true);
  final progress = StreamController<ChapterDownloadSnapshot>.broadcast(sync: true);
  final drained = Completer<void>();
  @override
  List<ImportedLibraryEntry> get activeDownloadEntries => List.unmodifiable(entries);
  @override
  Stream<void> get downloadExecutionChanges => execution.stream;
  @override
  Stream<ChapterDownloadSnapshot> get changes => progress.stream;
  @override
  Future<void> cancel(ImportedLibraryEntry entry) async {
    cancelled.add(entry);
    await drained.future;
    entries.remove(entry);
    execution.add(null);
  }
  @override
  Future<void> close() async {
    await execution.close();
    await progress.close();
  }
}

final _entry = ImportedLibraryEntry(chapter: ImportedChapterRecord(
  directoryId: 'background-fixture', displayName: 'Private chapter title',
  sourceId: 'fixture', comicId: 'comic', chapterId: 'chapter', sourceRevision: 'r1',
  pages: const [ImportedPageRecord(displayName: '1.png', sourceId: 'file:///fixture/1.png',
    contentKindHint: ContentKindHint.png)],
));

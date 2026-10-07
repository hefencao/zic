import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/material.dart';
import 'package:storage_bridge/storage_bridge.dart';
import 'package:zic/debug_trace_export.dart';
import 'package:zic/home_library_session.dart';
import 'package:zic/home_source_migration_transaction.dart';

// Explicit device entrypoint. Only fixture-owned SQLite/body files are opened.
// Barriers await real journal/body/library commits before an ADB kill. They
// neither create journal phases nor replace transaction/recovery behavior.
const _run = String.fromEnvironment('ZIC_MIGRATION_ACCEPTANCE_RUN',
    defaultValue: '20261003-migration-v3');
const _sourceId = 'fixture:migration-source';
const _otherSourceId = 'fixture:migration-target';
final _checks = <Map<String, Object?>>[];
late Directory _root;
enum _InsideCallback { artifactBinding, metadataProgress, cleanupChapter }

final _cases = <({String name, bool crossSource, SourceMigrationPhase? stop, _InsideCallback? inside})>[
  (name: 'same-source', crossSource: false, stop: null, inside: null),
  (name: 'cross-source', crossSource: true, stop: null, inside: null),
  for (final phase in SourceMigrationPhase.values)
    (name: 'kill-${phase.name}', crossSource: false, stop: phase, inside: null),
  (name: 'kill-artifact-callback', crossSource: false,
    stop: SourceMigrationPhase.prepared, inside: _InsideCallback.artifactBinding),
  (name: 'kill-metadata-callback', crossSource: false,
    stop: SourceMigrationPhase.artifactsReady, inside: _InsideCallback.metadataProgress),
  (name: 'kill-cleanup-callback', crossSource: false,
    stop: SourceMigrationPhase.cleanupPending, inside: _InsideCallback.cleanupChapter),
];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _show('准备隔离迁移验收');
  try {
    _root = Directory('${Directory.systemTemp.path}/zic-$_run');
    await _root.create(recursive: true);
    final checksFile = File('${_root.path}/checks.json');
    if (await checksFile.exists()) {
      _checks.addAll((jsonDecode(await checksFile.readAsString()) as List)
          .cast<Map>().map((value) => Map<String, Object?>.from(value)));
    }
    final cursorFile = File('${_root.path}/cursor.json');
    var cursor = await cursorFile.exists()
        ? Map<String, Object?>.from(jsonDecode(await cursorFile.readAsString()) as Map)
        : <String, Object?>{'case': 0, 'stage': 'execute'};
    while ((cursor['case'] as int) < _cases.length) {
      final index = cursor['case'] as int;
      await _runCase(index, recovering: cursor['stage'] == 'recover');
      cursor = <String, Object?>{'case': index + 1, 'stage': 'execute'};
      await cursorFile.writeAsString(jsonEncode(cursor), flush: true);
    }
    await _export('completed');
    _show('迁移隔离验收完成：${_checks.length} 项');
  } on Object catch (error, stack) {
    _checks.add(<String, Object?>{'status': 'failed', 'error': '$error',
      'stack': '$stack'});
    await _export('failed');
    _show('迁移隔离验收失败：$error');
  }
}

void _show(String message) => runApp(MaterialApp(home: Scaffold(
  body: Center(child: Text(message, textAlign: TextAlign.center)),
)));

void _check(String name, bool passed, {Map<String, Object?>? observed}) {
  _checks.add(<String, Object?>{'step': name,
    'status': passed ? 'passed' : 'failed', if (observed != null) 'observed': observed});
  File('${_root.path}/checks.json').writeAsStringSync(jsonEncode(_checks), flush: true);
  if (!passed) throw StateError(name);
}

Future<void> _export(String status, {int? index, SourceMigrationPhase? phase, String? site}) async {
  await exportDebugTraceFile(
    suggestedName: 'zic-source-migration-$_run-'
        '${DateTime.now().millisecondsSinceEpoch}.json',
    relativeDirectory: 'Debug',
    bytes: Uint8List.fromList(utf8.encode(jsonEncode(<String, Object?>{
      'run': _run, 'status': status, 'caseIndex': index, 'phase': phase?.name,
      'interruptionSite': site,
      'checks': _checks, 'temporaryRoot': _root.path, 'userStoresOpened': false,
      'scope': 'Production transaction/session with real isolated SQLite and '
          'physical artifact files; controlled source. Not normal main UI, '
          'live-origin, alias presentation or performance acceptance.',
    }))),
  );
}

Future<void> _runCase(int index, {required bool recovering}) async {
  final fixture = _cases[index];
  final source = _MigrationSource(_sourceId, 'old-comic');
  final target = _MigrationSource(
    fixture.crossSource ? _otherSourceId : _sourceId, 'new-comic', target: true,
  );
  final caseRoot = Directory('${_root.path}/${fixture.name}');
  await caseRoot.create(recursive: true);
  final library = await openImportedLibraryStore(caseRoot.path);
  final artifacts = await PersistentDownloadArtifactStore.open('${caseRoot.path}/artifacts');
  final migrationId = sourceMigrationJournalId(
    sourceSourceId: source.sourceId, sourceComicId: source.comicId,
    targetSourceId: target.sourceId, targetComicId: target.comicId,
  );
  Future<void> pause(SourceMigrationPhase phase, String site) async {
    await File('${_root.path}/cursor.json').writeAsString(jsonEncode(
      <String, Object?>{'case': index, 'stage': 'recover'}), flush: true);
    final checkpoint = (await (library as SourceMigrationJournalStore)
      .getSourceMigrationJournal(migrationId))!;
    _check('${fixture.name}-pause-observes-real-journal-phase', checkpoint.phase == phase);
    await _verifyCheckpoint(fixture.name, library, artifacts, source, target, phase,
      inside: fixture.inside);
    await _export('paused', index: index, phase: phase, site: site);
    _show('等待终止并重启：${fixture.name}');
    await Completer<void>().future;
  }
  final firstTarget = target.chapter('new:1');
  final firstTargetId = readerPageDownloadId(firstTarget, firstTarget.pages.first);
  final bodyBindings = <DownloadId>[];
  final bodyBackend = _ArtifactBindingBarrier(artifacts, onBinding: (id) async {
    bodyBindings.add(id);
    if (!recovering && fixture.inside == _InsideCallback.artifactBinding && id == firstTargetId) {
      await pause(SourceMigrationPhase.prepared, 'inside-artifact-binding');
    }
  });
  final cache = ArtifactCacheManager(backend:
    fixture.inside == _InsideCallback.artifactBinding ? bodyBackend : artifacts);
  final delegate = _JournalBarrierStore(library, onCommit: (record, unchanged) async {
    _check('${fixture.name}-journal-${record.phase.name}-does-not-bump-projection', unchanged);
    if (!recovering && fixture.inside == null && record.phase == fixture.stop) {
      await pause(record.phase, 'phase-boundary');
    }
  }, onMutation: (stage, chapterId) async {
    if (recovering) return;
    if (fixture.inside == _InsideCallback.metadataProgress &&
        stage == 'progress' && chapterId == 'new:1') {
      await pause(SourceMigrationPhase.artifactsReady, 'inside-metadata-progress');
    } else if (fixture.inside == _InsideCallback.cleanupChapter &&
        stage == 'remove-chapter' && chapterId.startsWith('old:')) {
      await pause(SourceMigrationPhase.cleanupPending, 'inside-cleanup-chapter');
    }
  });
  // The session starts loading its projection in its constructor. Seed before
  // constructing it so read-state startup cannot race fixture preparation.
  if (!recovering) await _seed(library, cache, artifacts, source, target);
  final downloads = MemoryChapterDownloadService(pageLoader: (_, _) async =>
    throw StateError('Fixture must not download pages'));
  final queue = WholeComicDownloadQueue(downloads: downloads);
  final session = HomeLibrarySession(
    library: delegate, chapterDownloads: downloads, wholeComicDownloads: queue,
    sources: recovering ? const <BrowsableComicSource>[] : <BrowsableComicSource>[source, target],
    ownsLibrary: false, ownsChapterDownloads: true, ownsWholeComicDownloads: true,
  );
  var recoverySourceCalls = 0;
  final transaction = HomeSourceMigrationTransaction(
    session: session, ensureDurableLibrary: () async {}, artifactCache: () => cache,
    verifiedPageReuseIdentity: ({required sourceId, required locator}) async {
      recoverySourceCalls++;
      throw StateError('No runtime/resolver fallback in migration fixture');
    },
    savePreference: session.persistPreference,
    canonicalComicIdForPersistence: (_, _, {fallback}) => fallback,
    reportError: (message, error) => throw StateError('$message: $error'),
  );
  try {
    await session.ready;
    if (recovering) {
      final checkpoint = (await (library as SourceMigrationJournalStore).getSourceMigrationJournal(migrationId))!;
      _check('${fixture.name}-durable-phase-survives-process-kill',
        checkpoint.phase == fixture.stop);
      await _verifyCheckpoint(fixture.name, library, artifacts, source, target, checkpoint.phase,
        inside: fixture.inside);
      final beforeSourceLoads = source.loads + target.loads;
      final recovered = await transaction.recoverCommitted();
      if (checkpoint.phase == SourceMigrationPhase.done) {
        _check('${fixture.name}-done-excluded-from-pending', !recovered);
        _check('${fixture.name}-done-resume-removes-journal',
          await transaction.resumeCommitted(migrationId));
      } else {
        _check('${fixture.name}-recovery-respects-metadata-commit',
          recovered == checkpoint.targetMetadataCommitted);
      }
      _check('${fixture.name}-recovery-does-not-call-offline-target',
        source.loads + target.loads == beforeSourceLoads && recoverySourceCalls == 0);
      if (!checkpoint.targetMetadataCommitted) {
        _check('${fixture.name}-precommit-recovery-keeps-source',
          await library.getSavedComic(source.sourceId, source.comicId) != null &&
          await (library as SourceMigrationJournalStore).getSourceMigrationJournal(migrationId) != null);
        await _execute(fixture.name, library, session, transaction, source, target,
          replacing: !fixture.crossSource,
          replayedProgress: fixture.inside == _InsideCallback.metadataProgress);
        if (fixture.inside == _InsideCallback.artifactBinding) {
          _check('${fixture.name}-replay-skips-already-durable-body-binding',
            !bodyBindings.contains(firstTargetId) && bodyBindings.length == 1,
            observed: <String, Object?>{'newBindingCalls': bodyBindings.length});
        }
      }
    } else {
      await _execute(fixture.name, library, session, transaction, source, target,
        replacing: !fixture.crossSource);
    }
    await _verifyFinal(fixture.name, library, session, cache, artifacts, source, target,
      replacing: !fixture.crossSource);
    _check('${fixture.name}-second-recovery-is-idempotent',
      !await transaction.recoverCommitted() && !await transaction.resumeCommitted(migrationId));
    _check('${fixture.name}-journal-removed',
      await (library as SourceMigrationJournalStore).getSourceMigrationJournal(migrationId) == null);
  } finally {
    await session.close();
    session.dispose();
    await library.close();
    await artifacts.close();
  }
  final reopened = await openImportedLibraryStore(caseRoot.path);
  final reopenedArtifacts = await PersistentDownloadArtifactStore.open('${caseRoot.path}/artifacts');
  try {
    _check('${fixture.name}-final-library-state-survives-reopen',
      (await reopened.get(target.sourceId, 'new:1'))?.progress?.pageIndex == 1 &&
      await reopened.get(target.sourceId, 'new:2') == null);
    final first = target.chapter('new:1');
    final id = readerPageDownloadId(first, first.pages.first);
    final bytes = await ArtifactCacheManager(backend: reopenedArtifacts).readForeground(id);
    _check('${fixture.name}-target-exact-bytes-survive-reopen',
      bytes != null && _sameBytes(bytes.bytes, _body(1, 0)));
  } finally {
    await reopened.close();
    await reopenedArtifacts.close();
  }
}

Future<void> _seed(ImportedLibraryStore library, ArtifactCacheManager cache,
    PersistentDownloadArtifactStore artifacts, _MigrationSource source,
    _MigrationSource target) async {
  await library.upsertSavedComic(SavedComicRecord.fromManifest(source.manifest));
  await library.saveComicPreference(ComicPreference.defaults(
    sourceId: source.sourceId, comicId: source.comicId, sourceKind: ComicSourceKind.remote,
  ).copyWith(inShelf: true, liked: true, categoryIds: <String>{'source-category'},
    acknowledgedVersionComicId: 'known-version'));
  for (var number = 1; number <= 3; number++) {
    final chapter = source.chapter('old:$number');
    await library.upsertChapter(ImportedChapterRecord.remote(comic: source.manifest.comic, manifest: chapter));
    await library.saveProgress(ReadingProgress(
      sourceId: source.sourceId, comicId: source.comicId, chapterId: chapter.chapter.chapterId,
      pageIndex: 1, subPageOffset: 0.75, readerMode: ReaderMode.continuous,
      updatedAt: DateTime.utc(2026, 1, 1),
    ));
    await library.saveChapterReadState(ChapterReadState(
      sourceId: source.sourceId, comicId: source.comicId, chapterId: chapter.chapter.chapterId,
      isRead: true, updatedAt: DateTime.utc(2026, 1, 1),
    ));
    for (final page in chapter.pages) {
      final id = readerPageDownloadId(chapter, page);
      await cache.storePromotedArtifact(id: id, bytes: _body(number, page.index));
      final row = (await artifacts.index.get(id.key))!;
      await artifacts.index.put(row.copyWith(pinned: true));
    }
  }
  final existing = target.chapter('new:3');
  await library.upsertChapter(ImportedChapterRecord.remote(comic: target.manifest.comic, manifest: existing));
  await library.saveProgress(ReadingProgress(
    sourceId: target.sourceId, comicId: target.comicId, chapterId: 'new:3',
    pageIndex: 0, subPageOffset: 0.25, readerMode: ReaderMode.paged,
    updatedAt: DateTime.utc(2026, 2, 1),
  ));
  await library.saveChapterReadState(ChapterReadState(
    sourceId: target.sourceId, comicId: target.comicId, chapterId: 'new:3',
    isRead: false, updatedAt: DateTime.utc(2026, 2, 1),
  ));
  await library.saveComicPreference(ComicPreference.defaults(
    sourceId: target.sourceId, comicId: target.comicId, sourceKind: ComicSourceKind.remote,
  ).copyWith(collected: true, categoryIds: <String>{'target-category'}, customOrder: 3));
}

Future<void> _execute(String name, ImportedLibraryStore library,
    HomeLibrarySession session, HomeSourceMigrationTransaction transaction,
    _MigrationSource source, _MigrationSource target,
    {required bool replacing, bool replayedProgress = false}) async {
  final projection = aggregateImportedLibrary(await library.list(),
    savedComics: await library.listSavedComics()).singleWhere((comic) =>
      comic.sourceId == source.sourceId && comic.comicId == source.comicId);
  final plan = ComicSourceMigrationPlan.build(source: projection, target: target.manifest);
  _check('$name-plan-exact-and-sequence-only-remain-distinct',
    plan.chapterMatches.where((match) => match.confidence == ChapterMigrationConfidence.exact).length == 2 &&
    plan.chapterMatches.where((match) => match.confidence == ChapterMigrationConfidence.sequenceOnly).length == 1);
  final result = await transaction.executeConfirmed(
    sourceComic: projection, targetSource: target, targetManifest: target.manifest, plan: plan,
    replacingSource: replacing,
    sourcePreference: (await library.getComicPreference(source.sourceId, source.comicId))!,
    targetCustomOrder: 99,
  );
  _check('$name-only-exact-chapters-load-and-copy-state',
    target.loads == 2 && !target.loadedIds.contains('new:2') && result.migratedChapters == 2 &&
    result.migratedProgress == (replayedProgress ? 0 : 1) && result.migratedReadStates == 1 &&
    result.preservedTargetStates == (replayedProgress ? 3 : 2),
    observed: <String, Object?>{'targetLoads': target.loads, 'loadedIds': target.loadedIds,
      'migratedChapters': result.migratedChapters, 'migratedProgress': result.migratedProgress,
      'migratedReadStates': result.migratedReadStates, 'preservedTargetStates': result.preservedTargetStates});
  _check('$name-session-publishes-migrated-read-state',
    session.readStates[chapterLibraryIdentity(target.sourceId, 'new:1')]?.isRead == true);
}

Future<void> _verifyCheckpoint(String name, ImportedLibraryStore library,
    PersistentDownloadArtifactStore artifacts, _MigrationSource source,
    _MigrationSource target, SourceMigrationPhase phase, {_InsideCallback? inside}) async {
  final sourcePresent = await library.getSavedComic(source.sourceId, source.comicId) != null;
  final targetPresent = await library.getSavedComic(target.sourceId, target.comicId) != null;
  _check('$name-${phase.name}-metadata-has-correct-commit-boundary',
    targetPresent == (phase.index >= SourceMigrationPhase.metadataCommitted.index ||
      inside == _InsideCallback.metadataProgress) &&
    sourcePresent == (phase != SourceMigrationPhase.done));
  final chapter = target.chapter('new:1');
  final row = await artifacts.index.get(readerPageDownloadId(chapter, chapter.pages.first).key);
  _check('$name-${phase.name}-physical-target-precedes-metadata',
    (row != null) == (phase.index >= SourceMigrationPhase.artifactsReady.index ||
      inside == _InsideCallback.artifactBinding));
  if (inside == _InsideCallback.artifactBinding) {
    final third = target.chapter('new:3');
    _check('$name-first-body-bound-before-second-body-or-metadata',
      await artifacts.index.get(readerPageDownloadId(third, third.pages.first).key) == null &&
      await library.get(target.sourceId, 'new:1') == null);
  } else if (inside == _InsideCallback.metadataProgress) {
    final copied = await library.get(target.sourceId, 'new:1');
    final reads = await library.listChapterReadStates(target.sourceId, target.comicId);
    _check('$name-progress-committed-before-read-state-or-phase-commit',
      copied?.progress?.pageIndex == 1 && copied?.progress?.subPageOffset == 0.75 &&
      !reads.any((state) => state.chapterId == 'new:1'));
  } else if (inside == _InsideCallback.cleanupChapter) {
    final remaining = (await library.list()).where((entry) =>
      entry.chapter.sourceId == source.sourceId && entry.chapter.comicId == source.comicId);
    final preference = await library.getComicPreference(source.sourceId, source.comicId);
    _check('$name-one-old-chapter-removed-with-two-and-old-comic-remaining',
      remaining.length == 2 && sourcePresent && preference?.inShelf != true);
  }
}

Future<void> _verifyFinal(String name, ImportedLibraryStore library,
    HomeLibrarySession session, ArtifactCacheManager cache,
    PersistentDownloadArtifactStore artifacts, _MigrationSource source,
    _MigrationSource target, {required bool replacing}) async {
  final copied = (await library.get(target.sourceId, 'new:1'))!;
  final retained = (await library.get(target.sourceId, 'new:3'))!;
  final reads = await library.listChapterReadStates(target.sourceId, target.comicId);
  _check('$name-copied-progress-binds-target-native-identity',
    copied.progress?.sourceId == target.sourceId && copied.progress?.comicId == target.comicId &&
    copied.progress?.chapterId == 'new:1' && copied.progress?.pageIndex == 1 &&
    copied.progress?.subPageOffset == 0.75);
  _check('$name-target-existing-progress-and-explicit-unread-preserved',
    retained.progress?.pageIndex == 0 && retained.progress?.subPageOffset == 0.25 &&
    retained.progress?.readerMode == ReaderMode.paged &&
    reads.singleWhere((state) => state.chapterId == 'new:3').isRead == false &&
    session.readStates[chapterLibraryIdentity(target.sourceId, 'new:3')]?.isRead == false);
  _check('$name-sequence-only-has-no-import-or-progress-or-read-state',
    await library.get(target.sourceId, 'new:2') == null &&
    !reads.any((state) => state.chapterId == 'new:2'));
  final sourcePreference = await library.getComicPreference(source.sourceId, source.comicId);
  final preference = (await library.getComicPreference(target.sourceId, target.comicId))!;
  _check('$name-target-preferences-merge-without-erasing-own-state',
    preference.inShelf && preference.liked && preference.collected && preference.customOrder == 3 &&
    preference.categoryIds.containsAll(<String>{'source-category', 'target-category'}));
  _check('$name-version-acknowledgement-is-source-scoped',
    preference.acknowledgedVersionComicId == (replacing ? 'known-version' : null));
  _check('$name-source-metadata-cleanup-follows-replacing-policy',
    (await library.getSavedComic(source.sourceId, source.comicId) == null) == replacing &&
    (await library.get(source.sourceId, 'old:1') == null) == replacing &&
    (replacing ? sourcePreference?.inShelf != true : sourcePreference?.inShelf == true));
  final oldChapter = source.chapter('old:1');
  final newChapter = target.chapter('new:1');
  final oldRow = (await artifacts.index.get(readerPageDownloadId(oldChapter, oldChapter.pages.first).key))!;
  final newRow = (await artifacts.index.get(readerPageDownloadId(newChapter, newChapter.pages.first).key))!;
  _check('$name-media-proof-reuses-one-body-with-independent-retention',
    oldRow.effectiveArtifactId == newRow.effectiveArtifactId && oldRow.path == newRow.path &&
    oldRow.pinned && !newRow.pinned &&
    (await artifacts.artifactReplicasFor(readerPageDownloadId(newChapter, newChapter.pages.first))).length == 1);
  _check('$name-exact-metadata-does-not-prove-unmatched-media',
    await artifacts.index.get(readerPageDownloadId(newChapter, newChapter.pages.last).key) == null);
  final sequenceChapter = target.chapter('new:2');
  _check('$name-sequence-only-does-not-materialize-even-with-media-proof',
    await artifacts.index.get(readerPageDownloadId(sequenceChapter, sequenceChapter.pages.first).key) == null);
  final oldBytes = await cache.readForeground(readerPageDownloadId(oldChapter, oldChapter.pages.first));
  _check('$name-source-offline-body-survives-metadata-cleanup',
    oldBytes != null && _sameBytes(oldBytes.bytes, _body(1, 0)));
}

Uint8List _body(int chapter, int page) => Uint8List.fromList(<int>[
  0x52, 0x49, 0x46, 0x46, 0x18, 0x00, 0x00, 0x00,
  0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20, chapter, page,
]);

bool _sameBytes(Uint8List first, Uint8List second) =>
  first.length == second.length && List<int>.generate(first.length, (i) => i)
    .every((index) => first[index] == second[index]);

final class _MigrationSource implements BrowsableComicSource {
  _MigrationSource(this.sourceId, this.comicId, {this.target = false});
  @override
  final String sourceId;
  final String comicId;
  final bool target;
  int loads = 0;
  final loadedIds = <String>[];
  @override
  ComicSourceDescriptor get descriptor => ComicSourceDescriptor(
    sourceId: sourceId, name: 'Isolated migration source', language: 'en',
    website: Uri.https('example.invalid'),
  );
  ComicManifest get manifest => ComicManifest(
    comic: Comic(sourceId: sourceId, comicId: comicId, title: 'Fixture comic',
      authors: const <String>[], readingDirection: ReadingDirection.ltr),
    chapters: <Chapter>[for (var number = 1; number <= 3; number++)
      chapter('${target ? 'new' : 'old'}:$number').chapter],
  );
  ChapterManifest chapter(String id) {
    final number = int.parse(id.split(':').last);
    return ChapterManifest(
      sourceId: sourceId, comicId: comicId, readingDirection: ReadingDirection.ltr,
      chapter: Chapter(chapterId: id, comicId: comicId,
        title: target && number == 2 ? 'Other edition' : 'Chapter $number',
        sequence: number, pageCount: 2, sourceRevision: target ? 'target-r1' : 'source-r1'),
      pages: <PageAsset>[for (var index = 0; index < 2; index++) PageAsset(
        pageId: '$id:$index', chapterId: id, index: index,
        uri: index == 0
          ? Uri.https('example.invalid', '/${List.filled(32, number).join()}.jpg')
          : Uri.https('example.invalid', '/$comicId/$id/other.jpg'),
        contentKindHint: ContentKindHint.webp,
      )],
    );
  }
  @override
  Future<ChapterManifest> loadChapter(String chapterId) async {
    loads++;
    loadedIds.add(chapterId);
    return chapter(chapterId);
  }
  @override
  Future<ComicManifest> loadComic(String comicId) => throw StateError('No comic lookup in fixture');
  @override
  Future<SourceBrowsePage> browse({String query = '', int offset = 0, int limit = 24}) =>
    throw StateError('No browse in fixture');
  @override
  Future<Uint8List> loadResource(Uri uri) => throw StateError('No transport in fixture');
}

// Transparent fixture decorator. All authority and revisions stay in SQLite;
// only acknowledged journal commits are observed/paused by this entrypoint.
final class _JournalBarrierStore implements ImportedLibraryStore, SourceMigrationJournalStore {
  _JournalBarrierStore(this.delegate, {required this.onCommit, required this.onMutation});
  final ImportedLibraryStore delegate;
  SourceMigrationJournalStore get journal => delegate as SourceMigrationJournalStore;
  Future<int?> get revision => (delegate as ImportedLibraryRevisionStore).libraryProjectionRevision;
  final Future<void> Function(SourceMigrationJournalRecord, bool) onCommit;
  final Future<void> Function(String stage, String chapterId) onMutation;
  @override
  Future<SourceMigrationJournalRecord> beginSourceMigrationJournal(SourceMigrationJournalRecord record) async {
    final before = await revision;
    final committed = await journal.beginSourceMigrationJournal(record);
    await onCommit(committed, before == await revision);
    return committed;
  }
  @override
  Future<SourceMigrationJournalRecord> advanceSourceMigrationJournal(String id,
      {required SourceMigrationPhase phase, required DateTime updatedAt}) async {
    final before = await revision;
    final committed = await journal.advanceSourceMigrationJournal(id, phase: phase, updatedAt: updatedAt);
    await onCommit(committed, before == await revision);
    return committed;
  }
  @override
  Future<SourceMigrationJournalRecord?> getSourceMigrationJournal(String id) => journal.getSourceMigrationJournal(id);
  @override
  Future<List<SourceMigrationJournalRecord>> listPendingSourceMigrations() => journal.listPendingSourceMigrations();
  @override
  Future<void> removeSourceMigrationJournal(String id) => journal.removeSourceMigrationJournal(id);
  @override
  Future<void> open() => delegate.open();
  @override
  Future<void> close() => delegate.close();
  @override
  Future<List<ImportedLibraryEntry>> list() => delegate.list();
  @override
  Future<ImportedLibraryEntry?> get(String sourceId, String chapterId) => delegate.get(sourceId, chapterId);
  @override
  Future<void> upsertChapter(ImportedChapterRecord chapter) => delegate.upsertChapter(chapter);
  @override
  Future<void> saveProgress(ReadingProgress progress) async {
    await delegate.saveProgress(progress);
    await onMutation('progress', progress.chapterId);
  }
  @override
  Future<void> removeChapter(String sourceId, String chapterId) async {
    await delegate.removeChapter(sourceId, chapterId);
    await onMutation('remove-chapter', chapterId);
  }
  @override
  Future<List<SavedComicRecord>> listSavedComics() => delegate.listSavedComics();
  @override
  Future<SavedComicRecord?> getSavedComic(String sourceId, String comicId) => delegate.getSavedComic(sourceId, comicId);
  @override
  Future<void> upsertSavedComic(SavedComicRecord comic) => delegate.upsertSavedComic(comic);
  @override
  Future<void> removeSavedComic(String sourceId, String comicId) => delegate.removeSavedComic(sourceId, comicId);
  @override
  Future<List<LibraryCategory>> listCategories() => delegate.listCategories();
  @override
  Future<void> upsertCategory(LibraryCategory category) => delegate.upsertCategory(category);
  @override
  Future<void> removeCategory(String categoryId) => delegate.removeCategory(categoryId);
  @override
  Future<List<ComicPreference>> listComicPreferences() => delegate.listComicPreferences();
  @override
  Future<ComicPreference?> getComicPreference(String sourceId, String comicId) => delegate.getComicPreference(sourceId, comicId);
  @override
  Future<void> saveComicPreference(ComicPreference preference) => delegate.saveComicPreference(preference);
  @override
  Future<List<ChapterReadState>> listChapterReadStates(String sourceId, String comicId) => delegate.listChapterReadStates(sourceId, comicId);
  @override
  Future<List<ChapterReadState>> listAllChapterReadStates() => delegate.listAllChapterReadStates();
  @override
  Future<void> saveChapterReadState(ChapterReadState state) => delegate.saveChapterReadState(state);
  @override
  Future<List<ComicSourcePreference>> listSourcePreferences() => delegate.listSourcePreferences();
  @override
  Future<void> saveSourcePreference(ComicSourcePreference preference) => delegate.saveSourcePreference(preference);
  @override
  Future<List<LibraryMigrationIssue>> listMigrationIssues({bool includeAcknowledged = false}) =>
    delegate.listMigrationIssues(includeAcknowledged: includeAcknowledged);
  @override
  Future<void> acknowledgeMigrationIssues(Iterable<int> ids, {required DateTime acknowledgedAt}) =>
    delegate.acknowledgeMigrationIssues(ids, acknowledgedAt: acknowledgedAt);
}

// Only the artifact-callback case needs this observer. Reads and zero-copy
// binding remain in the real persistent backend; no replica or phase is injected.
final class _ArtifactBindingBarrier implements ArtifactCacheBackend, ArtifactCacheBindingBackend {
  _ArtifactBindingBarrier(this.delegate, {required this.onBinding});
  final PersistentDownloadArtifactStore delegate;
  final Future<void> Function(DownloadId id) onBinding;
  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) => delegate.openArtifactStream(id);
  @override
  Future<void> storePromotedArtifact({required DownloadId id, required Uint8List bytes}) =>
    delegate.storePromotedArtifact(id: id, bytes: bytes);
  @override
  Future<void> invalidateArtifact(DownloadId id) => delegate.invalidateArtifact(id);
  @override
  Future<bool> bindExistingArtifact({required DownloadId sourceId, required DownloadId targetId}) async {
    final bound = await delegate.bindExistingArtifact(sourceId: sourceId, targetId: targetId);
    if (bound) await onBinding(targetId);
    return bound;
  }
}

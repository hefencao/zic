import 'dart:async';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/source_migration_compare.dart';

void main() {
  testWidgets('migration comparison requires explicit identity acknowledgement',
      (tester) async {
    final source = LibraryComic.fromSaved(
      SavedComicRecord(
        sourceId: 'source-a',
        comicId: 'comic-a',
        title: '当前漫画',
        authors: const <String>['作者 A'],
        readingDirection: ReadingDirection.ltr,
        chapters: const <SavedChapterRecord>[],
      ),
    );
    final target = ComicManifest(
      comic: const Comic(
        sourceId: 'source-b',
        comicId: 'comic-b',
        title: '目标漫画',
        authors: <String>['作者 B'],
        readingDirection: ReadingDirection.rtl,
      ),
      chapters: const <Chapter>[],
    );
    final plan = ComicSourceMigrationPlan.build(
      source: source,
      target: target,
    );
    bool? confirmed;
    var sourceCoverLoads = 0;
    var targetCoverLoads = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                confirmed = await showSourceMigrationComparison(
                  context: context,
                  plan: plan,
                  sourceName: '来源 A',
                  targetName: '来源 B',
                  sourceWebUri: Uri.parse('https://source.example/comic/a'),
                  targetWebUri: Uri.parse('https://target.example/comic/b'),
                  loadSourceCover: () async {
                    sourceCoverLoads++;
                    return Uint8List(0);
                  },
                  loadTargetCover: () async {
                    targetCoverLoads++;
                    return Uint8List(0);
                  },
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(sourceMigrationComparisonDialogKey), findsOneWidget);
    expect(find.byKey(sourceMigrationComparisonSourceKey), findsOneWidget);
    expect(find.byKey(sourceMigrationComparisonTargetKey), findsOneWidget);
    expect(find.byKey(sourceMigrationComparisonRisksKey), findsOneWidget);
    expect(find.text('当前漫画'), findsOneWidget);
    expect(find.text('目标漫画'), findsOneWidget);
    expect(find.text('https://source.example/comic/a'), findsOneWidget);
    expect(find.text('https://target.example/comic/b'), findsOneWidget);
    expect(find.text('source-a:comic-a'), findsNothing);
    expect(find.text('source-b:comic-b'), findsNothing);
    expect(find.byTooltip('关闭'), findsOneWidget);
    expect(find.text('取消'), findsNothing);
    expect(sourceCoverLoads, 1);
    expect(targetCoverLoads, 1);

    final disabled = tester.widget<FilledButton>(
      find.byKey(sourceMigrationComparisonConfirmKey),
    );
    expect(disabled.onPressed, isNull);

    await tester.ensureVisible(
      find.byKey(sourceMigrationComparisonAcknowledgeKey),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(sourceMigrationComparisonAcknowledgeKey));
    await tester.pump();
    expect(sourceCoverLoads, 1);
    expect(targetCoverLoads, 1);
    final enabled = tester.widget<FilledButton>(
      find.byKey(sourceMigrationComparisonConfirmKey),
    );
    expect(enabled.onPressed, isNotNull);

    await tester.tap(find.byKey(sourceMigrationComparisonConfirmKey));
    await tester.pump(const Duration(milliseconds: 250));
    expect(confirmed, isTrue);
  });

  testWidgets('confirmed version picker publishes the owner refresh and selects '
      'the refreshed exact object', (tester) async {
    const cached = SourceComicVersion(
      sourceId: 'fixture',
      comicId: 'venera:comic:cached-opaque',
      title: '缓存版本',
      generation: 1,
    );
    const refreshed = SourceComicVersion(
      sourceId: 'fixture',
      comicId: 'venera:comic:refreshed-opaque',
      title: '来源新版',
      generation: 2,
      date: '2026-09-29 19:52',
    );
    final refresh = Completer<List<SourceComicVersion>>();
    ({SourceComicVersion version, bool viewOnly})? selected;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              selected = await showConfirmedSourceVersionSelection(
                context: context,
                sourceName: 'Fixture',
                versions: const <SourceComicVersion>[cached],
                backgroundRefresh: refresh.future,
                webUriFor: (version) => Uri.parse(
                  'https://fixture.example/version/${version.generation}',
                ),
              );
            },
            child: const Text('打开版本'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开版本'));
    await tester.pumpAndSettle();
    expect(find.text('缓存版本'), findsOneWidget);
    expect(find.text('新版 · https://fixture.example/version/1'), findsOneWidget);
    expect(find.textContaining('venera:comic:'), findsNothing);

    refresh.complete(const <SourceComicVersion>[refreshed]);
    await tester.pumpAndSettle();
    expect(find.text('缓存版本'), findsNothing);
    expect(find.text('来源新版'), findsOneWidget);
    expect(find.text('新版 · 2026-09-29 19:52 · '
        'https://fixture.example/version/2'), findsOneWidget);
    await tester.tap(find.text('查看'));
    await tester.pumpAndSettle();
    expect(identical(selected!.version, refreshed), isTrue);
    expect(selected!.viewOnly, isTrue);
  });

  testWidgets('failed version refresh preserves cached exact migration choice',
      (tester) async {
    const cached = SourceComicVersion(
      sourceId: 'fixture',
      comicId: 'venera:comic:predecessor-opaque',
      title: '',
      generation: 1,
      isPredecessor: true,
    );
    final refresh = Completer<List<SourceComicVersion>>();
    ({SourceComicVersion version, bool viewOnly})? selected;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              selected = await showConfirmedSourceVersionSelection(
                context: context,
                sourceName: 'Fixture',
                versions: const <SourceComicVersion>[cached],
                backgroundRefresh: refresh.future,
                webUriFor: (_) => Uri.parse('https://fixture.example/old'),
              );
            },
            child: const Text('打开版本'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开版本'));
    await tester.pumpAndSettle();
    refresh.completeError(StateError('source refresh failed'));
    await tester.pumpAndSettle();
    expect(find.text('未命名版本'), findsOneWidget);
    expect(find.text('旧版 · https://fixture.example/old'), findsOneWidget);
    expect(find.textContaining('venera:comic:'), findsNothing);
    await tester.tap(find.text('迁移旧版状态'));
    await tester.pumpAndSettle();
    expect(identical(selected!.version, cached), isTrue);
    expect(selected!.viewOnly, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing version picker leaves admitted owner refresh intact',
      (tester) async {
    const version = SourceComicVersion(
      sourceId: 'fixture',
      comicId: 'venera:comic:opaque',
      title: '版本',
      generation: 1,
    );
    final refresh = Completer<List<SourceComicVersion>>();
    var selectionCompleted = false;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              final selected = await showConfirmedSourceVersionSelection(
                context: context,
                sourceName: 'Fixture',
                versions: const <SourceComicVersion>[version],
                backgroundRefresh: refresh.future,
                webUriFor: (_) => Uri.parse('https://fixture.example/version'),
              );
              expect(selected, isNull);
              selectionCompleted = true;
            },
            child: const Text('打开版本'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开版本'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(selectionCompleted, isTrue);
    expect(refresh.isCompleted, isFalse);
    refresh.complete(const <SourceComicVersion>[version]);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

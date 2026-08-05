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
    expect(find.text('source-a:comic-a'), findsOneWidget);
    expect(find.text('source-b:comic-b'), findsOneWidget);
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
}

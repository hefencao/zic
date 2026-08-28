import 'package:downloads/downloads.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storage/storage.dart';
import 'package:zic/comic_download_conflict_dialog.dart';

void main() {
  group('ComicDownloadConflictDialog Tests', () {
    testWidgets('no active candidates returns overwrite without opening dialog', (tester) async {
      late BuildContext testContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              testContext = context;
              return const Scaffold(body: Text('Home'));
            },
          ),
        ),
      );

      final report = const ComicConflictReport(
        candidates: <ComicFolderCandidate>[],
        hasDirectExactMatch: false,
        hasTitleConflicts: false,
        recommendedDirectoryName: '航海王',
      );

      final decision = await promptComicConflictResolution(
        context: testContext,
        report: report,
        comicTitle: '航海王',
        sourceId: 'copymanga',
      );

      expect(decision, ComicConflictDecision.overwrite);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('single candidate directly shows comparison dialog and supports overwrite', (tester) async {
      late BuildContext testContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              testContext = context;
              return const Scaffold(body: Text('Home'));
            },
          ),
        ),
      );

      final candidate = ComicFolderCandidate(
        directoryPath: '/downloads/航海王',
        folderName: '航海王',
        manifest: ComicFolderManifest(
          sourceId: 'copymanga',
          sourceDisplayName: '拷贝漫画',
          comicId: 'one_piece',
          comicTitle: '航海王',
          updatedAt: DateTime.utc(2026, 8, 28),
        ),
        isExactMatch: true,
        isTitleMatch: false,
        chapterCount: 0,
        existingPageFilesCount: 8,
      );

      final report = ComicConflictReport(
        candidates: <ComicFolderCandidate>[candidate],
        hasDirectExactMatch: true,
        hasTitleConflicts: false,
        recommendedDirectoryName: '航海王',
      );

      Future<ComicConflictDecision>? decisionFuture;
      decisionFuture = promptComicConflictResolution(
        context: testContext,
        report: report,
        comicTitle: '航海王',
        sourceId: 'copymanga',
        sourceDisplayName: '拷贝漫画',
        chapterTitle: '第 1 话',
      );

      await tester.pumpAndSettle();

      // Comparison dialog is displayed directly
      expect(find.text('对比本地文件与待下载内容'), findsOneWidget);
      expect(find.text('本地已有目录'), findsOneWidget);
      expect(find.text('本次待下载内容'), findsOneWidget);
      expect(find.text('100% 完全匹配 (同源同ID)'), findsOneWidget);
      expect(find.text('8 个图片文件 · 单章节图集'), findsOneWidget);
      expect(find.text('第 1 话'), findsOneWidget);

      // Tap overwrite
      await tester.tap(find.text('覆盖并下载'));
      await tester.pumpAndSettle();

      final decision = await decisionFuture;
      expect(decision, ComicConflictDecision.overwrite);
    });

    testWidgets('multiple candidates shows selection list with confidence, then diff comparison', (tester) async {
      late BuildContext testContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              testContext = context;
              return const Scaffold(body: Text('Home'));
            },
          ),
        ),
      );

      final c1 = ComicFolderCandidate(
        directoryPath: '/downloads/航海王',
        folderName: '航海王',
        manifest: ComicFolderManifest(
          sourceId: 'copymanga',
          sourceDisplayName: '拷贝漫画',
          comicId: 'one_piece',
          comicTitle: '航海王',
          updatedAt: DateTime.utc(2026, 8, 28),
        ),
        isExactMatch: true,
        isTitleMatch: false,
        chapterCount: 0,
        existingPageFilesCount: 8,
      );

      final c2 = ComicFolderCandidate(
        directoryPath: '/downloads/航海王 (动漫之家)',
        folderName: '航海王 (动漫之家)',
        manifest: ComicFolderManifest(
          sourceId: 'dmzj',
          sourceDisplayName: '动漫之家',
          comicId: 'one_piece_dmzj',
          comicTitle: '航海王',
          updatedAt: DateTime.utc(2026, 8, 20),
        ),
        isExactMatch: false,
        isTitleMatch: true,
        chapterCount: 1,
        existingPageFilesCount: 20,
      );

      final report = ComicConflictReport(
        candidates: <ComicFolderCandidate>[c1, c2],
        hasDirectExactMatch: true,
        hasTitleConflicts: true,
        recommendedDirectoryName: '航海王 (拷贝漫画 2)',
      );

      Future<ComicConflictDecision>? decisionFuture;
      decisionFuture = promptComicConflictResolution(
        context: testContext,
        report: report,
        comicTitle: '航海王',
        sourceId: 'copymanga',
        sourceDisplayName: '拷贝漫画',
        chapterTitle: '第 1 话',
      );

      await tester.pumpAndSettle();

      // Candidate selection dialog is displayed with confidence badges
      expect(find.text('发现多个相似下载目录'), findsOneWidget);
      expect(find.text('100% 完全匹配 (同源同ID)'), findsOneWidget);
      expect(find.text('85% 同名候选 (动漫之家)'), findsOneWidget);

      // Select the first candidate
      await tester.tap(find.text('航海王'));
      await tester.pumpAndSettle();

      // Now diff comparison dialog is shown for that candidate
      expect(find.text('对比本地文件与待下载内容'), findsOneWidget);
      expect(find.text('8 个图片文件 · 单章节图集'), findsOneWidget);

      // Choose "另存为新目录"
      await tester.tap(find.text('另存为新目录'));
      await tester.pumpAndSettle();

      final decision = await decisionFuture;
      expect(decision, ComicConflictDecision.saveAsNew);
    });
  });
}

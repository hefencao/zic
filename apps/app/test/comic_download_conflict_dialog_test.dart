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

      final result = await promptComicConflictResolutionResult(
        context: testContext,
        report: report,
        comicTitle: '航海王',
        sourceId: 'copymanga',
      );

      expect(result.decision, ComicConflictDecision.overwrite);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('single exact match candidate shows task handling dialog and supports replace old task', (tester) async {
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
        versionRelation: ComicVersionRelationKind.sameVersion,
      );

      final report = ComicConflictReport(
        candidates: <ComicFolderCandidate>[candidate],
        hasDirectExactMatch: true,
        hasTitleConflicts: false,
        recommendedDirectoryName: '航海王',
      );

      Future<ComicConflictResolutionResult>? decisionFuture;
      decisionFuture = promptComicConflictResolutionResult(
        context: testContext,
        report: report,
        comicTitle: '航海王',
        sourceId: 'copymanga',
        sourceDisplayName: '拷贝漫画',
        chapterTitle: '第 1 话',
      );

      await tester.pumpAndSettle();

      // Comparison dialog is displayed directly
      expect(find.text('下载任务处理'), findsOneWidget);
      expect(find.text('检测到同名已下载内容'), findsOneWidget);
      expect(find.text('新建任务（可展开对比）'), findsOneWidget);
      expect(find.text('新任务替换旧任务'), findsOneWidget);

      // Tap overwrite / replace
      await tester.tap(find.text('新任务替换旧任务'));
      await tester.pumpAndSettle();

      final result = await decisionFuture;
      expect(result.decision, ComicConflictDecision.overwrite);
    });

    testWidgets('incoming is newer version defaults to replace old task and supports expand comparison', (tester) async {
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
          sourceId: 'ehentai',
          sourceDisplayName: 'E-Hentai',
          comicId: '12345/old',
          comicTitle: '航海王',
          updatedAt: DateTime.utc(2026, 8, 20),
        ),
        isExactMatch: false,
        isTitleMatch: true,
        chapterCount: 0,
        existingPageFilesCount: 20,
        versionRelation: ComicVersionRelationKind.incomingIsNewer,
      );

      final report = ComicConflictReport(
        candidates: <ComicFolderCandidate>[candidate],
        hasDirectExactMatch: false,
        hasTitleConflicts: true,
        recommendedDirectoryName: '航海王',
      );

      Future<ComicConflictResolutionResult>? decisionFuture;
      decisionFuture = promptComicConflictResolutionResult(
        context: testContext,
        report: report,
        comicTitle: '航海王',
        sourceId: 'ehentai',
        sourceDisplayName: 'E-Hentai',
        chapterTitle: '整本漫画',
      );

      await tester.pumpAndSettle();

      expect(find.text('下载任务处理'), findsOneWidget);
      expect(find.text('发现新版本更新'), findsOneWidget);
      expect(find.text('新任务替换旧任务'), findsOneWidget);

      // Expand the comparison panel
      await tester.tap(find.text('新建任务（可展开对比）'));
      await tester.pumpAndSettle();

      expect(find.text('本地已有目录'), findsOneWidget);
      expect(find.text('本次待下载内容'), findsOneWidget);
      final saveAsNewFinder = find.text('另存为新目录并新建任务');
      expect(saveAsNewFinder, findsOneWidget);
      await tester.ensureVisible(saveAsNewFinder);
      await tester.pumpAndSettle();

      // Tap save as new
      await tester.tap(saveAsNewFinder);
      await tester.pumpAndSettle();

      final result = await decisionFuture;
      expect(result.decision, ComicConflictDecision.saveAsNew);
    });

    testWidgets('existing is newer version defaults to do nothing (cancel)', (tester) async {
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
          sourceId: 'ehentai',
          sourceDisplayName: 'E-Hentai',
          comicId: '67890/new',
          comicTitle: '航海王',
          updatedAt: DateTime.utc(2026, 8, 28),
        ),
        isExactMatch: false,
        isTitleMatch: true,
        chapterCount: 0,
        existingPageFilesCount: 30,
        versionRelation: ComicVersionRelationKind.existingIsNewer,
      );

      final report = ComicConflictReport(
        candidates: <ComicFolderCandidate>[candidate],
        hasDirectExactMatch: false,
        hasTitleConflicts: true,
        recommendedDirectoryName: '航海王',
      );

      Future<ComicConflictResolutionResult>? decisionFuture;
      decisionFuture = promptComicConflictResolutionResult(
        context: testContext,
        report: report,
        comicTitle: '航海王',
        sourceId: 'ehentai',
        sourceDisplayName: 'E-Hentai',
        chapterTitle: '整本漫画',
      );

      await tester.pumpAndSettle();

      expect(find.text('下载任务处理'), findsOneWidget);
      expect(find.text('本地已存在更新版本'), findsOneWidget);
      expect(find.text('保持现有版本（什么都不做）'), findsOneWidget);
      expect(find.text('仍要替换为旧版本'), findsOneWidget);

      // Default action: tap "保持现有版本（什么都不做）"
      await tester.tap(find.text('保持现有版本（什么都不做）'));
      await tester.pumpAndSettle();

      final result = await decisionFuture;
      expect(result.decision, ComicConflictDecision.cancel);
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

      Future<ComicConflictResolutionResult>? decisionFuture;
      decisionFuture = promptComicConflictResolutionResult(
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

      // Choose "新建独立任务" directly
      await tester.tap(find.text('新建独立任务'));
      await tester.pumpAndSettle();

      final result = await decisionFuture;
      expect(result.decision, ComicConflictDecision.saveAsNew);
    });
  });
}

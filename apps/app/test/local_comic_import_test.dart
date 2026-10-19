import 'dart:convert';
import 'dart:io';

import 'package:catalog/catalog.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/local_comic_import_screen.dart';
import 'package:zic/local_comic_import_source.dart';
import 'package:zic/webp_demo.dart';

final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6jXcAAAAASUVORK5CYII=');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('zic-local-comic-test-'));
  tearDown(() async { if (await root.exists()) await root.delete(recursive: true); });

  Future<void> write(String path) async {
    final file = File('${root.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(_png);
  }

  test('linked folder refresh preserves its chapter boundary and legacy recursion', () async {
    await write('Original/1.png');
    await write('Original/Nested/2.png');
    final tree = DirectoryExternalDownloadTree('${root.path}/Original');
    final scan = await ExternalDownloadScanner().scan(tree);
    final comic = scan.comics.singleWhere((comic) => comic.path.isEmpty);
    final record = await linkedLocalComicChapter(tree, comic, comic.chapters.single,
      checkCancelled: () {});
    expect(record.sourceId, 'local-folder');
    expect(record.pages, hasLength(1));
    expect(record.pages.single.sourceId, '${root.path}/Original/1.png');
    final restored = ImportedChapterRecord.fromJson(record.toJson());
    expect(restored.directoryRecursive, false);
    expect(restored.copyWith(displayName: 'Renamed').directoryRecursive, false);
    expect((await refreshPickedImageFolder(restored)).files, hasLength(1));
    final legacy = Map<String, Object?>.from(record.toJson())..remove('directoryRecursive');
    expect((await refreshPickedImageFolder(ImportedChapterRecord.fromJson(legacy))).files, hasLength(2));
    expect(await File(record.pages.single.sourceId).readAsBytes(), _png);
    expect(await Directory(root.path).list().length, 1,
      reason: 'direct reading must not create a durable media copy');
  });

  test('linking rejects every App format and CBZ before accessing source bytes', () async {
    final tree = DirectoryExternalDownloadTree(root.path);
    for (final format in [ExternalDownloadFormat.ehViewer, ExternalDownloadFormat.mihon,
        ExternalDownloadFormat.venera, ExternalDownloadFormat.localFolder]) {
      final chapter = ExternalDownloadChapter(path: 'missing', title: 'Chapter',
        pages: const ['missing/1.png'], archive: format == ExternalDownloadFormat.localFolder);
      final comic = ExternalDownloadComic(path: 'missing', title: 'Comic',
        format: format, chapters: [chapter]);
      await expectLater(linkedLocalComicChapter(tree, comic, chapter,
        checkCancelled: () {}), throwsFormatException);
    }
  });

  testWidgets('ordinary directory defaults to copying and direct reading requires selection', (tester) async {
    await tester.runAsync(() => write('Ordinary/1.png'));
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('dev.zic.zic/startup');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,
      (call) async => call.method == 'applicationSupportPath' ? root.path : null);
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    var copies = 0;
    var links = 0;
    await tester.pumpWidget(MaterialApp(home: LocalComicImportScreen(
      directoryPicker: () async => '${root.path}/Ordinary', stopImports: () async {},
      importChapter: (prepared, {required checkCancelled}) async {
        copies++;
        expect(await prepared.files.values.single.readAsBytes(), _png);
        return ImportedLibraryEntry(chapter: prepared.record);
      },
      linkChapter: (tree, comic, chapter, {required checkCancelled}) async {
        links++;
        return ImportedLibraryEntry(chapter: await linkedLocalComicChapter(tree, comic, chapter,
          checkCancelled: checkCancelled));
      },
    )));
    await tester.tap(find.text('选择目录'));
    await _wait(tester, () => find.byType(SegmentedButton<LocalComicImportMode>).evaluate().isNotEmpty);
    final selector = tester.widget<SegmentedButton<LocalComicImportMode>>(find.byType(SegmentedButton<LocalComicImportMode>));
    expect(selector.selected, {LocalComicImportMode.copy});
    await tester.ensureVisible(find.text('导入所选漫画'));
    await tester.tap(find.text('导入所选漫画'));
    await _wait(tester, () => find.text('完成 1 章，失败 0 章').evaluate().isNotEmpty);
    expect(copies, 1);
    expect(links, 0);
    await tester.ensureVisible(find.text('直接读取'));
    await tester.tap(find.text('直接读取'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('导入所选漫画'));
    await tester.tap(find.text('导入所选漫画'));
    await _wait(tester, () => links == 1 && find.text('完成 1 章，失败 0 章').evaluate().isNotEmpty);
    expect(copies, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });
}

Future<void> _wait(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 20));
    if (ready()) return;
  }
  throw TestFailure('Local comic import did not settle');
}

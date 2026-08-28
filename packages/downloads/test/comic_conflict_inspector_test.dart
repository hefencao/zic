import 'dart:io';
import 'dart:typed_data';

import 'package:downloads/downloads.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  group('ComicConflictInspector Tests', () {
    test('returns clean recommended name when directory is empty', () async {
      final temp = await Directory.systemTemp.createTemp('conflict-test-empty');
      addTearDown(() => temp.delete(recursive: true));

      final report = await inspectPosixComicConflicts(
        rootDirectory: temp.path,
        sourceId: 'copymanga',
        sourceDisplayName: '拷贝漫画',
        comicId: 'one_piece',
        comicTitle: '航海王',
      );

      expect(report.candidates, isEmpty);
      expect(report.hasDirectExactMatch, isFalse);
      expect(report.hasTitleConflicts, isFalse);
      expect(report.recommendedDirectoryName, '航海王');
    });

    test('detects exact matching comic directory by .zic.json manifest', () async {
      final temp = await Directory.systemTemp.createTemp('conflict-test-exact');
      addTearDown(() => temp.delete(recursive: true));

      final comicDir = Directory('${temp.path}/航海王');
      await comicDir.create(recursive: true);

      final manifest = ComicFolderManifest(
        sourceId: 'copymanga',
        sourceDisplayName: '拷贝漫画',
        comicId: 'one_piece',
        comicTitle: '航海王',
        updatedAt: DateTime.utc(2026, 8, 27),
      );
      final manifestFile = File('${comicDir.path}/$comicManifestFileName');
      await manifestFile.writeAsString(manifest.encode());

      final report = await inspectPosixComicConflicts(
        rootDirectory: temp.path,
        sourceId: 'copymanga',
        sourceDisplayName: '拷贝漫画',
        comicId: 'one_piece',
        comicTitle: '航海王',
      );

      expect(report.candidates.length, 1);
      expect(report.candidates.first.isExactMatch, isTrue);
      expect(report.hasDirectExactMatch, isTrue);
      expect(report.hasTitleConflicts, isFalse);
      expect(report.recommendedDirectoryName, '航海王');
    });

    test('detects title collision with different source and suggests disambiguated name', () async {
      final temp = await Directory.systemTemp.createTemp('conflict-test-diff');
      addTearDown(() => temp.delete(recursive: true));

      // Existing folder belongs to dmzj
      final existingDir = Directory('${temp.path}/航海王');
      await existingDir.create(recursive: true);

      final manifest = ComicFolderManifest(
        sourceId: 'dmzj',
        sourceDisplayName: '动漫之家',
        comicId: 'one_piece_dmzj',
        comicTitle: '航海王',
        updatedAt: DateTime.utc(2026, 8, 27),
      );
      final manifestFile = File('${existingDir.path}/$comicManifestFileName');
      await manifestFile.writeAsString(manifest.encode());

      // Now inspecting for copymanga
      final report = await inspectPosixComicConflicts(
        rootDirectory: temp.path,
        sourceId: 'copymanga',
        sourceDisplayName: '拷贝漫画',
        comicId: 'one_piece_copy',
        comicTitle: '航海王',
      );

      expect(report.candidates.length, 1);
      expect(report.candidates.first.isExactMatch, isFalse);
      expect(report.candidates.first.isTitleMatch, isTrue);
      expect(report.hasDirectExactMatch, isFalse);
      expect(report.hasTitleConflicts, isTrue);
      expect(report.recommendedDirectoryName, '航海王 (拷贝漫画)');
    });

    test('detects existing page files in folder and flags hasExistingFiles', () async {
      final temp = await Directory.systemTemp.createTemp('conflict-test-pages');
      addTearDown(() => temp.delete(recursive: true));

      final comicDir = Directory('${temp.path}/航海王');
      await comicDir.create(recursive: true);
      final p1 = File('${comicDir.path}/001.webp');
      await p1.writeAsBytes(<int>[1, 2, 3]);
      final p2 = File('${comicDir.path}/002.webp');
      await p2.writeAsBytes(<int>[4, 5, 6]);

      final report = await inspectPosixComicConflicts(
        rootDirectory: temp.path,
        sourceId: 'ehentai',
        comicId: 'gallery_123',
        comicTitle: '航海王',
      );

      expect(report.candidates.length, 1);
      expect(report.candidates.first.existingPageFilesCount, 2);
      expect(report.hasExistingFiles, isTrue);
      expect(report.matchingCandidate, isNotNull);
    });

    test('inspectSafComicConflicts detects existing SAF manifest and pages', () async {
      final fakeSaf = _FakeSafTreeIo();
      fakeSaf.files['航海王/.zic.json'] = <int>[123, 125]; // dummy manifest bytes
      fakeSaf.files['航海王/001.webp'] = <int>[1, 2, 3];
      fakeSaf.files['航海王/002.webp'] = <int>[4, 5, 6];

      final report = await inspectSafComicConflicts(
        safIo: fakeSaf,
        safTreeUri: 'content://tree/gallery',
        sourceId: 'ehentai',
        comicId: 'gallery_123',
        comicTitle: '航海王',
      );

      expect(report.candidates.length, 1);
      expect(report.candidates.first.folderName, '航海王');
      expect(report.candidates.first.existingPageFilesCount, 2);
      expect(report.hasExistingFiles, isTrue);
    });

    test('detects suffixed directories like [拷贝漫画] 航海王 and 航海王 (1)', () async {
      final temp = await Directory.systemTemp.createTemp('conflict-test-suffix');
      addTearDown(() => temp.delete(recursive: true));

      final suffixedDir1 = Directory('${temp.path}/航海王 (1)');
      await suffixedDir1.create(recursive: true);
      await File('${suffixedDir1.path}/001.webp').writeAsBytes(<int>[1, 2]);

      final suffixedDir2 = Directory('${temp.path}/[拷贝漫画] 航海王');
      await suffixedDir2.create(recursive: true);
      await File('${suffixedDir2.path}/001.webp').writeAsBytes(<int>[3, 4]);

      final report = await inspectPosixComicConflicts(
        rootDirectory: temp.path,
        sourceId: 'copymanga',
        sourceDisplayName: '拷贝漫画',
        comicId: 'one_piece_copy',
        comicTitle: '航海王',
      );

      expect(report.candidates.length, 2);
      expect(report.hasExistingFiles, isTrue);
      expect(report.hasTitleConflicts, isTrue);
    });

    test('detects custom suffixed folders for complex bracketed titles like [武器屋]海賊（ワンピース）（test）', () async {
      final fakeSaf = _FakeSafTreeIo();
      fakeSaf.files['[武器屋]海賊（ワンピース）/.zic.json'] = <int>[123];
      fakeSaf.files['[武器屋]海賊（ワンピース）（test）/.zic.json'] = <int>[123];

      final report = await inspectSafComicConflicts(
        safIo: fakeSaf,
        safTreeUri: 'content://tree/gallery',
        sourceId: 'ehentai',
        comicId: 'gallery_123',
        comicTitle: '[武器屋]海賊（ワンピース）',
      );

      expect(report.candidates.length, 2);
      expect(
        report.candidates.map((c) => c.folderName),
        containsAll(<String>[
          '[武器屋]海賊（ワンピース）',
          '[武器屋]海賊（ワンピース）（test）',
        ]),
      );
    });
  });
}

final class _FakeSafTreeIo implements SafTreeIo {
  final Map<String, List<int>> files = <String, List<int>>{};

  @override
  Future<int?> open(String relativePath, {SafWriteMode mode = SafWriteMode.read}) async =>
      files.containsKey(relativePath) ? 1 : null;

  @override
  Future<Uint8List> read(int handle, int length) async {
    for (final bytes in files.values) {
      return Uint8List.fromList(bytes);
    }
    return Uint8List(0);
  }

  @override
  Future<void> write(int handle, Uint8List bytes) async {}

  @override
  Future<int?> length(int handle) async => 2;

  @override
  Future<void> seek(int handle, int position) async {}

  @override
  Future<void> close(int handle) async {}

  @override
  Future<bool> delete(String relativePath) async {
    return files.remove(relativePath) != null;
  }

  @override
  Future<bool> exists(String relativePath) async =>
      files.containsKey(relativePath);

  @override
  Future<List<SafTreeFile>> list(String relativePath) async {
    final prefix = relativePath.isEmpty ? '' : '$relativePath/';
    final result = <SafTreeFile>[];
    final seen = <String>{};
    for (final path in files.keys) {
      if (prefix.isEmpty) {
        final segments = path.split('/');
        if (segments.length > 1 && seen.add(segments.first)) {
          result.add(
            SafTreeFile(name: segments.first, isDirectory: true, length: 0),
          );
        }
      } else if (path.startsWith(prefix)) {
        final sub = path.substring(prefix.length);
        final segments = sub.split('/');
        if (segments.length == 1 && seen.add(segments.first)) {
          result.add(
            SafTreeFile(
              name: segments.first,
              isDirectory: false,
              length: files[path]?.length ?? 0,
            ),
          );
        } else if (segments.length > 1 && seen.add(segments.first)) {
          result.add(
            SafTreeFile(name: segments.first, isDirectory: true, length: 0),
          );
        }
      }
    }
    return result;
  }
}

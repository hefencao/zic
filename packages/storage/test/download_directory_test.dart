import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory workspace;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('zic-download-dir');
  });

  tearDown(() async {
    if (await workspace.exists()) {
      await workspace.delete(recursive: true);
    }
  });

  Directory dir(String relative) => Directory(
        '${workspace.path}${Platform.pathSeparator}'
        '$relative',
      );

  test('default directory lives under the storage root', () {
    expect(
      defaultChapterDownloadDirectory('${workspace.path}/root'),
      '${workspace.path}${Platform.pathSeparator}root'
      '${Platform.pathSeparator}offline_chapters',
    );
  });

  test('resolver creates a missing picked directory', () async {
    final picked = dir('picked');
    final resolved = await resolveChapterDownloadDirectory(picked.path);
    expect(resolved, picked.path);
    expect(await picked.exists(), isTrue);
  });

  test('resolver reuses an empty picked directory', () async {
    final picked = dir('picked');
    await picked.create(recursive: true);
    final resolved = await resolveChapterDownloadDirectory(picked.path);
    expect(resolved, picked.path);
  });

  test('resolver parks the store beside foreign content without merging',
      () async {
    final picked = dir('picked');
    await picked.create(recursive: true);
    File(
      '${picked.path}${Platform.pathSeparator}keep.txt',
    ).writeAsStringSync('user data');

    final resolved = await resolveChapterDownloadDirectory(picked.path);
    expect(
      resolved,
      '${picked.path}${Platform.pathSeparator}offline_chapters',
    );
    expect(Directory(resolved).existsSync(), isTrue);
    expect(File('${picked.path}${Platform.pathSeparator}keep.txt').existsSync(),
        isTrue);
  });

  test('resolver skips taken entries and reuses empty ones', () async {
    final picked = dir('picked');
    await picked.create(recursive: true);
    final separator = Platform.pathSeparator;
    final taken = Directory(
      '${picked.path}${separator}offline_chapters',
    );
    await taken.create();
    File('${taken.path}${separator}cache.sqlite').writeAsStringSync('db');

    expect(
      await resolveChapterDownloadDirectory(picked.path),
      '${picked.path}${separator}offline_chapters(1)',
    );

    // An existing but empty candidate stays reusable instead of growing the
    // suffix chain forever.
    await Directory(
      '${picked.path}${separator}offline_chapters(1)',
    ).create();

    expect(
      await resolveChapterDownloadDirectory(picked.path),
      '${picked.path}${separator}offline_chapters(1)',
    );
  });

  test('hasContent detects an index or stored bytes', () async {
    final store = dir('store');
    expect(chapterDownloadStoreHasContent(store.path), isFalse);
    await store.create(recursive: true);
    expect(chapterDownloadStoreHasContent(store.path), isFalse);

    File('${store.path}${Platform.pathSeparator}cache.sqlite')
        .writeAsStringSync('db');
    expect(chapterDownloadStoreHasContent(store.path), isTrue);
  });

  test('move relocates index and bytes together', () async {
    final from = dir('from');
    final to = dir('to');
    final separator = Platform.pathSeparator;
    await Directory('${from.path}${separator}partial').create(recursive: true);
    await Directory('${from.path}${separator}final').create(recursive: true);
    File('${from.path}${separator}partial${separator}a.part')
        .writeAsBytesSync(<int>[1]);
    File('${from.path}${separator}final${separator}a.bin')
        .writeAsBytesSync(<int>[1, 2, 3]);
    _seedEntryDb(from.path, <String>[]);

    final report = await moveChapterDownloadStore(from: from.path, to: to.path);

    expect(report.movedFileCount, 3);
    expect(report.rewrittenRecordCount, 0);
    expect(
      File('${to.path}${separator}cache.sqlite').existsSync(),
      isTrue,
    );
    expect(
      File('${to.path}${separator}final${separator}a.bin').readAsBytesSync(),
      <int>[1, 2, 3],
    );
    expect(
      File('${from.path}${separator}final${separator}a.bin').existsSync(),
      isFalse,
    );
  });

  test('move rewrites indexed paths onto the new prefix', () async {
    final from = dir('from');
    final to = dir('nested-target');
    final separator = Platform.pathSeparator;
    await Directory('${from.path}${separator}final').create(recursive: true);
    File('${from.path}${separator}cache.sqlite').writeAsStringSync('');
    _seedEntryDb(from.path, <String>[
      '${from.path}${separator}final${separator}a.bin',
      '${from.path}${separator}final${separator}b.bin',
      '/somewhere/else${separator}c.bin',
    ]);

    final report =
        await moveChapterDownloadStore(from: from.path, to: to.path);

    expect(report.rewrittenRecordCount, 2);
    final paths = _readEntryPaths(to.path);
    expect(paths, containsAll(<String>[
      '${to.path}${separator}final${separator}a.bin',
      '${to.path}${separator}final${separator}b.bin',
    ]));
    expect(paths, contains('/somewhere/else${separator}c.bin'));
  });

  test('move completes a partially failed earlier attempt', () async {
    final from = dir('from');
    final to = dir('to');
    final separator = Platform.pathSeparator;
    await Directory('${from.path}${separator}final').create(recursive: true);
    await Directory('${to.path}${separator}final').create(recursive: true);
    File('${from.path}${separator}final${separator}late.bin')
        .writeAsBytesSync(<int>[9]);

    final report =
        await moveChapterDownloadStore(from: from.path, to: to.path);

    expect(report.movedFileCount, 1);
    expect(
      File('${to.path}${separator}final${separator}late.bin').existsSync(),
      isTrue,
    );
  });

  test('move rejects nested, equal, or contentless sources', () async {
    final from = dir('from');
    final separator = Platform.pathSeparator;
    await Directory('${from.path}${separator}final').create(recursive: true);
    File('${from.path}${separator}cache.sqlite').writeAsStringSync('');

    await expectLater(
      moveChapterDownloadStore(from: from.path, to: from.path),
      throwsArgumentError,
    );
    await expectLater(
      moveChapterDownloadStore(
        from: from.path,
        to: '${from.path}${separator}inner',
      ),
      throwsArgumentError,
    );
    await expectLater(
      moveChapterDownloadStore(
        from: from.path,
        to: dir('outside').parent.path,
      ),
      throwsArgumentError,
    );
    final empty = dir('empty-store');
    await empty.create(recursive: true);
    await expectLater(
      moveChapterDownloadStore(from: empty.path, to: dir('to').path),
      throwsArgumentError,
    );
  });
}

sql.Database _openEntryDb(String storePath) {
  final separator = Platform.pathSeparator;
  return sql.sqlite3.open('${storePath}${separator}cache.sqlite');
}

void _seedEntryDb(String storePath, List<String> paths) {
  final db = _openEntryDb(storePath);
  db.execute(
    'CREATE TABLE cache_entry (key TEXT NOT NULL PRIMARY KEY, '
    'path TEXT NOT NULL)',
  );
  for (var index = 0; index < paths.length; index++) {
    db.execute(
      'INSERT INTO cache_entry (key, path) VALUES (?, ?)',
      <Object?>['k$index', paths[index]],
    );
  }
  db.close();
}

List<String> _readEntryPaths(String storePath) {
  final db = _openEntryDb(storePath);
  try {
    return db
        .select('SELECT path FROM cache_entry ORDER BY key')
        .map((row) => row['path']! as String)
        .toList(growable: false);
  } finally {
    db.close();
  }
}

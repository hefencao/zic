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

  test('resolver rejects symbolic-link parents and store candidates', () async {
    if (Platform.isWindows) return;
    final realParent = dir('real-parent');
    await realParent.create(recursive: true);
    final parentLink = Link(dir('parent-link').path);
    await parentLink.create(realParent.path);
    await expectLater(
      resolveChapterDownloadDirectory(parentLink.path),
      throwsStateError,
    );

    final picked = dir('picked-with-link');
    await picked.create(recursive: true);
    File('${picked.path}${Platform.pathSeparator}keep.txt')
        .writeAsStringSync('user data');
    final realStore = dir('real-store');
    await realStore.create(recursive: true);
    final storeLink = Link(
      '${picked.path}${Platform.pathSeparator}offline_chapters',
    );
    await storeLink.create(realStore.path);
    await expectLater(
      resolveChapterDownloadDirectory(picked.path),
      throwsStateError,
    );
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

  test('move only rewrites root identity for records whose paths moved',
      () async {
    final from = dir('from-with-roots');
    final to = dir('to-with-roots');
    final separator = Platform.pathSeparator;
    await Directory('${from.path}${separator}final').create(recursive: true);
    File('${from.path}${separator}final${separator}page.bin')
        .writeAsBytesSync(<int>[1]);
    final db = _openEntryDb(from.path);
    db.execute(
      'CREATE TABLE cache_entry (key TEXT NOT NULL PRIMARY KEY, '
      'path TEXT NOT NULL, storage_root_id TEXT NOT NULL)',
    );
    db.execute(
      'INSERT INTO cache_entry (key, path, storage_root_id) VALUES (?, ?, ?)',
      <Object?>[
        'moved',
        '${from.path}${separator}final${separator}page.bin',
        'default',
      ],
    );
    db.execute(
      'INSERT INTO cache_entry (key, path, storage_root_id) VALUES (?, ?, ?)',
      <Object?>['external', '/another/root/page.bin', 'default'],
    );
    db.close();

    await moveChapterDownloadStore(from: from.path, to: to.path);

    final movedDb = _openEntryDb(to.path);
    try {
      final rows = movedDb.select(
        'SELECT key, path, storage_root_id FROM cache_entry ORDER BY key',
      );
      expect(rows[0]['key'], 'external');
      expect(rows[0]['path'], '/another/root/page.bin');
      expect(rows[0]['storage_root_id'], 'default');
      expect(rows[1]['key'], 'moved');
      expect(
        rows[1]['path'],
        '${to.path}${separator}final${separator}page.bin',
      );
      expect(rows[1]['storage_root_id'], to.path);
    } finally {
      movedDb.close();
    }
  });

  test('move preflights directory/file shape conflicts before moving', () async {
    final from = dir('from-shape-conflict');
    final to = dir('to-shape-conflict');
    final separator = Platform.pathSeparator;
    await Directory('${from.path}${separator}final').create(recursive: true);
    final sourceFile = File(
      '${from.path}${separator}final${separator}page.bin',
    );
    await sourceFile.writeAsBytes(const <int>[1, 2, 3]);
    _seedEntryDb(from.path, <String>[]);
    await to.create(recursive: true);
    await File('${to.path}${separator}final').writeAsString('not a directory');

    await expectLater(
      moveChapterDownloadStore(from: from.path, to: to.path),
      throwsStateError,
    );
    expect(await sourceFile.exists(), isTrue);
    expect(
      await File('${to.path}${separator}final').readAsString(),
      'not a directory',
    );
  });

  test('move does not silently leave symbolic links behind', () async {
    if (Platform.isWindows) return;
    final from = dir('from-with-link');
    final to = dir('to-with-link');
    final separator = Platform.pathSeparator;
    final finalDirectory = Directory(
      '${from.path}${separator}final',
    );
    await finalDirectory.create(recursive: true);
    final target = File('${from.path}${separator}outside.bin');
    await target.writeAsBytes(const <int>[7]);
    final link = Link(
      '${finalDirectory.path}${separator}outside-link.bin',
    );
    await link.create(target.path);
    _seedEntryDb(from.path, <String>[]);

    await expectLater(
      moveChapterDownloadStore(from: from.path, to: to.path),
      throwsStateError,
    );
    expect(
      await FileSystemEntity.type(link.path, followLinks: false),
      FileSystemEntityType.link,
    );
    // Preflight rejection must not leave a destination that would later be
    // mistaken for a partially migrated store by startup.
    expect(await to.exists(), isFalse);
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
        to: '${from.path}${Platform.pathSeparator}..'
            '${Platform.pathSeparator}${from.path.split(Platform.pathSeparator).last}',
      ),
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

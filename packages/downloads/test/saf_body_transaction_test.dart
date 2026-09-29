import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  const tree = 'content://tree/body';
  const target = 'partial/body.part';
  const backup = '$target.zic-old';
  const temporary = '$target.zic-tmp-crash';

  test('malformed SAF body intent releases metadata process ownership', () async {
    final root = await Directory.systemTemp.createTemp('zic-saf-body-bad-');
    addTearDown(() => root.delete(recursive: true));
    final indexPath = '${root.path}/chapter_downloads.sqlite';
    await _createIndex(indexPath);
    final directory = Directory('$indexPath.saf-body-transactions');
    await directory.create(recursive: true);
    final bad = File('${directory.path}/txn-bad.json');
    await bad.writeAsString('{bad', flush: true);
    final io = _MemorySafIo(<String, Uint8List>{});

    await expectLater(
      PersistentDownloadArtifactStore.open(
        root.path,
        indexPath: indexPath,
        safMirror: io,
        safTreeUri: tree,
      ),
      throwsA(isA<Object>()),
    );

    await bad.delete();
    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      indexPath: indexPath,
      safMirror: io,
      safTreeUri: tree,
    );
    await store.close();
  });

  test('store open retires orphan local body-intent staging temp', () async {
    final root = await Directory.systemTemp.createTemp('zic-saf-body-orphan-intent-');
    addTearDown(() => root.delete(recursive: true));
    final indexPath = '${root.path}/chapter_downloads.sqlite';
    await _createIndex(indexPath);
    final directory = Directory('$indexPath.saf-body-transactions');
    await directory.create(recursive: true);
    final orphan = File('${directory.path}/.txn-crashed.tmp');
    await orphan.writeAsString('{partial', flush: true);

    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      indexPath: indexPath,
      safMirror: _MemorySafIo(<String, Uint8List>{}),
      safTreeUri: tree,
    );
    addTearDown(store.close);

    expect(await orphan.exists(), isFalse);
  });

  test('crash after target backup restores old body when index stayed old', () async {
    final fixture = await _fixture('backup-only');
    addTearDown(fixture.dispose);
    await _putCache(fixture.indexPath, fixture.oldRecord);
    await _writeIntent(fixture.indexPath, fixture.newRecord, hadTarget: true);
    fixture.io.storage[backup] = fixture.oldBytes;
    fixture.io.storage[temporary] = fixture.newBytes;

    final store = await fixture.open();
    addTearDown(store.close);

    expect(fixture.io.storage[target], orderedEquals(fixture.oldBytes));
    expect(fixture.io.storage.containsKey(backup), isFalse);
    expect(fixture.io.storage.containsKey(temporary), isFalse);
    expect(await _intentFiles(fixture.indexPath), isEmpty);
    expect((await store.index.get(fixture.oldRecord.key))?.touchedUs,
        fixture.oldRecord.touchedUs);
  });

  test('same-length new target rolls back when body index commit did not happen', () async {
    final fixture = await _fixture('same-length-rollback');
    addTearDown(fixture.dispose);
    expect(fixture.oldBytes.length, fixture.newBytes.length);
    await _putCache(fixture.indexPath, fixture.oldRecord);
    await _writeIntent(fixture.indexPath, fixture.newRecord, hadTarget: true);
    fixture.io.storage[target] = fixture.newBytes;
    fixture.io.storage[backup] = fixture.oldBytes;

    final store = await fixture.open();
    addTearDown(store.close);

    expect(fixture.io.storage[target], orderedEquals(fixture.oldBytes));
    final current = await store.index.get(fixture.oldRecord.key);
    expect(current?.touchedUs, fixture.oldRecord.touchedUs,
        reason: 'same length must not be treated as commit evidence');
    expect(await _intentFiles(fixture.indexPath), isEmpty);
  });

  test('committed index with mismatched target fails store open closed',
      () async {
    final fixture = await _fixture('committed-mismatch');
    addTearDown(fixture.dispose);
    await _putCache(fixture.indexPath, fixture.newRecord);
    await _writeIntent(fixture.indexPath, fixture.newRecord, hadTarget: true);
    fixture.io.storage[target] = Uint8List.fromList(<int>[9, 9, 9]);
    fixture.io.storage[backup] = fixture.oldBytes;

    await expectLater(
      fixture.open(),
      throwsA(
        isA<Failure>().having(
          (value) => value.code,
          'code',
          ErrorCode.artifactCorruption,
        ),
      ),
    );
    expect(fixture.io.storage.containsKey(backup), isTrue,
        reason: 'ambiguous committed recovery must preserve rollback evidence');
    expect(await _intentFiles(fixture.indexPath), isNotEmpty);
  });

  test('committed body survives later touch before stale intent recovery',
      () async {
    final fixture = await _fixture('committed-after-touch');
    addTearDown(fixture.dispose);
    await _putCache(
      fixture.indexPath,
      fixture.newRecord.copyWith(touchedUs: 99),
    );
    await _writeIntent(fixture.indexPath, fixture.newRecord, hadTarget: true);
    fixture.io.storage[target] = fixture.newBytes;
    fixture.io.storage[backup] = fixture.oldBytes;

    final store = await fixture.open();
    addTearDown(store.close);

    expect(fixture.io.storage[target], orderedEquals(fixture.newBytes));
    expect(fixture.io.storage.containsKey(backup), isFalse);
    expect((await store.index.get(fixture.newRecord.key))?.touchedUs, 99,
        reason: 'touch time is not SAF body commit evidence');
    expect(await _intentFiles(fixture.indexPath), isEmpty);
  });

  test('committed same-path partial keeps new body and retires backup', () async {
    final fixture = await _fixture('committed-forward');
    addTearDown(fixture.dispose);
    await _putCache(fixture.indexPath, fixture.newRecord);
    await _writeIntent(fixture.indexPath, fixture.newRecord, hadTarget: true);
    fixture.io.storage[target] = fixture.newBytes;
    fixture.io.storage[backup] = fixture.oldBytes;

    final store = await fixture.open();
    addTearDown(store.close);

    expect(fixture.io.storage[target], orderedEquals(fixture.newBytes));
    expect(fixture.io.storage.containsKey(backup), isFalse);
    expect((await store.index.get(fixture.newRecord.key))?.touchedUs,
        fixture.newRecord.touchedUs);
    expect(await _intentFiles(fixture.indexPath), isEmpty);
  });

  test('physical partial commit evidence ignores later touch time',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-saf-body-physical-');
    addTearDown(() => root.delete(recursive: true));
    final indexPath = '${root.path}/chapter_downloads.sqlite';
    final id = PhysicalMediaId.canonical('physical-body');
    final oldBytes = Uint8List.fromList(<int>[1, 3, 5, 7, 9, 11, 13, 15]);
    final newBytes = Uint8List.fromList(<int>[2, 4, 6, 8, 10, 12, 14, 16]);
    final oldCrc = Crc32()..add(oldBytes);
    final newCrc = Crc32()..add(newBytes);
    final recordPath = encodeSafRecordPath(treeUri: tree, relativePath: target);
    final oldRecord = PhysicalPartialRecord(
      id: id,
      path: recordPath,
      bytes: oldBytes.length,
      checksum: oldCrc.hex,
      createdUs: 10,
      touchedUs: 20,
      storageRootId: tree,
    );
    final expected = oldRecord.copyWith(checksum: newCrc.hex, touchedUs: 30);
    final current = expected.copyWith(touchedUs: 99);
    final index = SqliteIndex(indexPath);
    await index.open();
    await index.putPhysicalPartial(current);
    await index.close();
    final directory = Directory('$indexPath.saf-body-transactions');
    await directory.create(recursive: true);
    await File('${directory.path}/txn-physical.json').writeAsString(
      jsonEncode(<String, Object?>{
        'version': 1,
        'treeUri': tree,
        'targetPath': target,
        'temporaryPath': temporary,
        'backupPath': backup,
        'hadTarget': true,
        'authorityKind': 'physicalPartial',
        'authority': <String, Object?>{
          'physicalMedia': expected.id.toJson(),
          'path': expected.path,
          'bytes': expected.bytes,
          'checksum': expected.checksum,
          'createdUs': expected.createdUs,
          'touchedUs': expected.touchedUs,
          'checksumAlgorithm': expected.checksumAlgorithm,
          'storageRootId': expected.storageRootId,
        },
        'bodyBytes': expected.bytes,
        'bodyChecksum': expected.checksum,
        'verifyChecksum': false,
      }),
      flush: true,
    );
    final io = _MemorySafIo(<String, Uint8List>{
      target: newBytes,
      backup: oldBytes,
    });

    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      indexPath: indexPath,
      safMirror: io,
      safTreeUri: tree,
    );

    expect(io.storage[target], orderedEquals(newBytes));
    expect(io.storage.containsKey(backup), isFalse);
    expect(await _intentFiles(indexPath), isEmpty);
    await store.close();

    final reopenedIndex = SqliteIndex(indexPath);
    await reopenedIndex.open();
    try {
      expect((await reopenedIndex.getPhysicalPartial(id))?.touchedUs, 99);
    } finally {
      await reopenedIndex.close();
    }
  });

  test('uncommitted first SAF body is removed instead of adopted', () async {
    final fixture = await _fixture('first-write');
    addTearDown(fixture.dispose);
    await _createIndex(fixture.indexPath);
    await _writeIntent(fixture.indexPath, fixture.newRecord, hadTarget: false);
    fixture.io.storage[target] = fixture.newBytes;

    final store = await fixture.open();
    addTearDown(store.close);

    expect(fixture.io.storage.containsKey(target), isFalse);
    expect(await store.index.get(fixture.newRecord.key), isNull);
    expect(await _intentFiles(fixture.indexPath), isEmpty);
  });
}

Future<_Fixture> _fixture(String name) async {
  final root = await Directory.systemTemp.createTemp('zic-saf-body-$name-');
  const tree = 'content://tree/body';
  final path = encodeSafRecordPath(treeUri: tree, relativePath: 'partial/body.part');
  final id = DownloadId(
    content: ContentId(
      sourceId: 'source',
      comicId: 'comic-$name',
      chapterId: 'chapter',
      pageId: 'page',
    ),
    sourceRevision: 'r1',
    canonicalUri: Uri.parse('https://example.test/$name.webp'),
  );
  final oldBytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
  final newBytes = Uint8List.fromList(<int>[8, 7, 6, 5, 4, 3, 2, 1]);
  final oldCrc = Crc32()..add(oldBytes);
  final newCrc = Crc32()..add(newBytes);
  final oldRecord = CacheRec(
    id: id,
    state: CacheState.partial,
    path: path,
    bytes: oldBytes.length,
    checksum: oldCrc.hex,
    createdUs: 10,
    touchedUs: 20,
    storageRootId: tree,
  );
  final newRecord = oldRecord.copyWith(
    checksum: newCrc.hex,
    touchedUs: 30,
  );
  return _Fixture(
    root: root,
    indexPath: '${root.path}/chapter_downloads.sqlite',
    io: _MemorySafIo(<String, Uint8List>{}),
    oldRecord: oldRecord,
    newRecord: newRecord,
    oldBytes: oldBytes,
    newBytes: newBytes,
  );
}

Future<void> _createIndex(String indexPath) async {
  final index = SqliteIndex(indexPath);
  await index.open();
  await index.close();
}

Future<void> _putCache(String indexPath, CacheRec record) async {
  final index = SqliteIndex(indexPath);
  await index.open();
  try {
    await index.put(record);
  } finally {
    await index.close();
  }
}

Future<void> _writeIntent(
  String indexPath,
  CacheRec expected, {
  required bool hadTarget,
}) async {
  final directory = Directory('$indexPath.saf-body-transactions');
  await directory.create(recursive: true);
  await File('${directory.path}/txn-test.json').writeAsString(
    jsonEncode(<String, Object?>{
      'version': 1,
      'treeUri': 'content://tree/body',
      'targetPath': 'partial/body.part',
      'temporaryPath': 'partial/body.part.zic-tmp-crash',
      'backupPath': 'partial/body.part.zic-old',
      'hadTarget': hadTarget,
      'authorityKind': 'cacheBinding',
      'authority': expected.toJson(),
      'bodyBytes': expected.bytes,
      'bodyChecksum': expected.checksum,
      'verifyChecksum': false,
    }),
    flush: true,
  );
}

Future<List<FileSystemEntity>> _intentFiles(String indexPath) async {
  final directory = Directory('$indexPath.saf-body-transactions');
  if (!await directory.exists()) return const <FileSystemEntity>[];
  return directory.list(followLinks: false).toList();
}

final class _Fixture {
  const _Fixture({
    required this.root,
    required this.indexPath,
    required this.io,
    required this.oldRecord,
    required this.newRecord,
    required this.oldBytes,
    required this.newBytes,
  });

  final Directory root;
  final String indexPath;
  final _MemorySafIo io;
  final CacheRec oldRecord;
  final CacheRec newRecord;
  final Uint8List oldBytes;
  final Uint8List newBytes;

  Future<PersistentDownloadArtifactStore> open() =>
      PersistentDownloadArtifactStore.open(
        root.path,
        indexPath: indexPath,
        safMirror: io,
        safTreeUri: 'content://tree/body',
      );

  Future<void> dispose() async {
    if (await root.exists()) await root.delete(recursive: true);
  }
}

final class _MemorySafIo implements SafTreeIo {
  _MemorySafIo(this.storage);

  final Map<String, Uint8List> storage;
  final Map<int, ({String path, int position})> _handles =
      <int, ({String path, int position})>{};
  int _nextHandle = 1;

  @override
  Future<int?> open(String relativePath, {SafWriteMode mode = SafWriteMode.read}) async {
    if (mode == SafWriteMode.read && !storage.containsKey(relativePath)) return null;
    if (mode == SafWriteMode.writeTruncate) storage[relativePath] = Uint8List(0);
    if (mode == SafWriteMode.writeAppend) {
      storage.putIfAbsent(relativePath, () => Uint8List(0));
    }
    final handle = _nextHandle++;
    _handles[handle] = (
      path: relativePath,
      position: mode == SafWriteMode.writeAppend
          ? storage[relativePath]!.lengthInBytes
          : 0,
    );
    return handle;
  }

  @override
  Future<Uint8List> read(int handle, int length) async {
    final state = _handles[handle]!;
    final bytes = storage[state.path]!;
    final end = (state.position + length).clamp(0, bytes.lengthInBytes);
    final result = Uint8List.fromList(bytes.sublist(state.position, end));
    _handles[handle] = (path: state.path, position: end);
    return result;
  }

  @override
  Future<void> write(int handle, Uint8List bytes) async {
    final state = _handles[handle]!;
    final current = storage[state.path] ?? Uint8List(0);
    storage[state.path] = Uint8List.fromList(<int>[
      ...current.sublist(0, state.position),
      ...bytes,
    ]);
    _handles[handle] = (
      path: state.path,
      position: state.position + bytes.lengthInBytes,
    );
  }

  @override
  Future<int?> length(int handle) async {
    final state = _handles[handle];
    return state == null ? null : storage[state.path]?.lengthInBytes;
  }

  @override
  Future<void> seek(int handle, int position) async {
    final state = _handles[handle]!;
    _handles[handle] = (path: state.path, position: position);
  }

  @override
  Future<void> close(int handle) async => _handles.remove(handle);

  @override
  Future<bool> delete(String relativePath) async =>
      storage.remove(relativePath) != null;

  @override
  Future<bool> rename(String relativePath, String newRelativePath) async {
    if (!storage.containsKey(relativePath) || storage.containsKey(newRelativePath)) {
      return false;
    }
    storage[newRelativePath] = storage.remove(relativePath)!;
    return true;
  }

  @override
  Future<bool> exists(String relativePath) async => storage.containsKey(relativePath);

  @override
  Future<List<SafTreeFile>> list(String relativePath) async =>
      const <SafTreeFile>[];
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  const tree = 'content://tree/downloads';
  const manifestPath = 'Comic/$comicManifestFileName';
  const backupPath = '$manifestPath.zic-old';

  test('failed SAF intent recovery releases metadata process ownership',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-saf-manifest-bad-intent-');
    addTearDown(() => root.delete(recursive: true));
    final indexPath = '${root.path}/chapter_downloads.sqlite';
    await _createIndex(indexPath);
    final intentDirectory = Directory('$indexPath.saf-manifest-transactions');
    await intentDirectory.create(recursive: true);
    final badIntent = File('${intentDirectory.path}/txn-bad.json');
    await badIntent.writeAsString('{bad', flush: true);
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

    await badIntent.delete();
    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      indexPath: indexPath,
      safMirror: io,
      safTreeUri: tree,
    );
    await store.close();
  });

  test('valid newer SAF target never advances placement without intent',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-saf-manifest-no-intent-');
    addTearDown(() => root.delete(recursive: true));
    final indexPath = '${root.path}/chapter_downloads.sqlite';
    final oldPlacement = _manifest(generation: 0, chapters: const <String>[]);
    final newerTarget = _manifest(generation: 1, chapters: const <String>['c1']);
    await _putPlacement(indexPath, tree, oldPlacement);
    final io = _MemorySafIo(<String, Uint8List>{
      manifestPath: _encoded(newerTarget),
    });

    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      indexPath: indexPath,
      safMirror: io,
      safTreeUri: tree,
    );
    addTearDown(store.close);

    final placement = await store.index.getPlacement(
      sourceId: 'source',
      comicId: 'comic',
    );
    expect(placement?.generation, oldPlacement.generation);
    expect(placement?.fingerprint, oldPlacement.fingerprint);
    expect(_decode(io.storage[manifestPath]!), _matches(newerTarget));
  });

  test('cold open does not probe SAF placements without durable intents',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-saf-manifest-lazy-');
    addTearDown(() => root.delete(recursive: true));
    final indexPath = '${root.path}/chapter_downloads.sqlite';
    final committed = _manifest(generation: 4, chapters: const <String>['c1']);
    await _putPlacement(indexPath, tree, committed);
    final io = _MemorySafIo(<String, Uint8List>{
      manifestPath: _encoded(committed),
    });

    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      indexPath: indexPath,
      safMirror: io,
      safTreeUri: tree,
    );
    addTearDown(store.close);

    expect(io.existsCalls, isEmpty,
        reason: 'Reader byte readiness does not need portable manifest probes');
  });

  test('concurrent selected manifest reads recover legacy backup once',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-saf-manifest-lazy-old-');
    addTearDown(() => root.delete(recursive: true));
    final indexPath = '${root.path}/chapter_downloads.sqlite';
    final committed = _manifest(generation: 4, chapters: const <String>['c1']);
    await _putPlacement(indexPath, tree, committed);
    final corrupt = Uint8List.fromList(utf8.encode('{uncommitted'));
    final io = _MemorySafIo(<String, Uint8List>{
      manifestPath: corrupt,
      backupPath: _encoded(committed),
    });
    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      indexPath: indexPath,
      safMirror: io,
      safTreeUri: tree,
    );
    addTearDown(store.close);
    expect(io.storage[manifestPath], orderedEquals(corrupt));

    await Future.wait(<Future<String>>[
      for (var i = 0; i < 2; i++)
        store.resolveStructuredChapterDirectory(
          _entry(chapterId: 'c1'), comicDirectoryName: 'Comic'),
    ]);

    expect(_decode(io.storage[manifestPath]!), _matches(committed));
    expect(io.storage.containsKey(backupPath), isFalse);
    final placement = await store.index.getPlacement(
      sourceId: 'source', comicId: 'comic');
    expect(placement?.generation, committed.generation);
    expect(placement?.fingerprint, committed.fingerprint);
  });

  test('selected legacy recovery rejects backup without matching authority',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-saf-manifest-lazy-bad-');
    addTearDown(() => root.delete(recursive: true));
    final indexPath = '${root.path}/chapter_downloads.sqlite';
    final committed = _manifest(generation: 4, chapters: const <String>['c1']);
    final uncommitted = _manifest(generation: 5, chapters: const <String>['c2']);
    await _putPlacement(indexPath, tree, committed);
    final io = _MemorySafIo(<String, Uint8List>{
      backupPath: _encoded(uncommitted),
    });
    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      indexPath: indexPath,
      safMirror: io,
      safTreeUri: tree,
    );
    addTearDown(store.close);

    await expectLater(store.resolveStructuredChapterDirectory(
      _entry(chapterId: 'c1'), comicDirectoryName: 'Comic'),
      throwsA(isA<Failure>().having(
        (failure) => failure.code, 'code', ErrorCode.artifactCorruption)));
    expect(io.storage.containsKey(manifestPath), isFalse);
    expect(io.storage[backupPath], orderedEquals(_encoded(uncommitted)));
    final placement = await store.index.getPlacement(
      sourceId: 'source', comicId: 'comic');
    expect(placement?.generation, committed.generation);
    expect(placement?.fingerprint, committed.fingerprint);
  });

  test('first SAF manifest crash rolls back target only with durable intent',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-saf-manifest-first-');
    addTearDown(() => root.delete(recursive: true));
    final indexPath = '${root.path}/chapter_downloads.sqlite';
    final oldPlacement = _manifest(generation: 0, chapters: const <String>[]);
    final firstManifest = _manifest(generation: 1, chapters: const <String>['c1']);
    await _putPlacement(indexPath, tree, oldPlacement);
    await _writeIntent(
      indexPath,
      tree: tree,
      operation: 'replace',
      oldPlacement: oldPlacement,
      oldManifest: null,
      nextManifest: firstManifest,
    );
    final io = _MemorySafIo(<String, Uint8List>{
      manifestPath: _encoded(firstManifest),
    });

    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      indexPath: indexPath,
      safMirror: io,
      safTreeUri: tree,
    );
    addTearDown(store.close);

    expect(io.storage.containsKey(manifestPath), isFalse);
    expect(await _intentFiles(indexPath), isEmpty);
    final placement = await store.index.getPlacement(
      sourceId: 'source',
      comicId: 'comic',
    );
    expect(placement?.generation, oldPlacement.generation);
    expect(placement?.fingerprint, oldPlacement.fingerprint);
  });

  test('SAF manifest intent rolls back target when placement stayed old',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-saf-manifest-old-');
    addTearDown(() => root.delete(recursive: true));
    final indexPath = '${root.path}/chapter_downloads.sqlite';
    final oldManifest = _manifest(generation: 4, chapters: const <String>['c1']);
    final newManifest = _manifest(
      generation: 5,
      chapters: const <String>['c1', 'c2'],
    );
    await _putPlacement(indexPath, tree, oldManifest);
    await _writeIntent(
      indexPath,
      tree: tree,
      operation: 'replace',
      oldPlacement: oldManifest,
      oldManifest: oldManifest,
      nextManifest: newManifest,
    );
    final io = _MemorySafIo(<String, Uint8List>{
      manifestPath: _encoded(newManifest),
      backupPath: _encoded(oldManifest),
    });

    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      indexPath: indexPath,
      safMirror: io,
      safTreeUri: tree,
    );
    addTearDown(store.close);

    expect(_decode(io.storage[manifestPath]!), _matches(oldManifest));
    expect(io.storage.containsKey(backupPath), isFalse);
    expect(await _intentFiles(indexPath), isEmpty);
  });

  test('SAF rollback preserves placement generation ahead of old manifest',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-saf-manifest-split-token-');
    addTearDown(() => root.delete(recursive: true));
    final indexPath = '${root.path}/chapter_downloads.sqlite';
    final oldManifest = _manifest(generation: 5, chapters: const <String>['c1']);
    final oldPlacement = oldManifest.copyWith(
      generation: 7,
      fingerprint: oldManifest.fingerprint,
    );
    final nextManifest = _manifest(
      generation: 8,
      chapters: const <String>['c1', 'c2'],
    );
    await _putPlacement(indexPath, tree, oldPlacement);
    await _writeIntent(
      indexPath,
      tree: tree,
      operation: 'replace',
      oldPlacement: oldPlacement,
      oldManifest: oldManifest,
      nextManifest: nextManifest,
    );
    final io = _MemorySafIo(<String, Uint8List>{
      manifestPath: _encoded(nextManifest),
      backupPath: _encoded(oldManifest),
    });

    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      indexPath: indexPath,
      safMirror: io,
      safTreeUri: tree,
    );
    addTearDown(store.close);

    expect(_decode(io.storage[manifestPath]!), _matches(oldManifest));
    final placement = await store.index.getPlacement(
      sourceId: 'source',
      comicId: 'comic',
    );
    expect(placement?.generation, 7);
    expect(placement?.fingerprint, oldManifest.fingerprint);
  });

  test('SAF manifest intent keeps target when placement already committed',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-saf-manifest-new-');
    addTearDown(() => root.delete(recursive: true));
    final indexPath = '${root.path}/chapter_downloads.sqlite';
    final oldManifest = _manifest(generation: 8, chapters: const <String>['c1']);
    final newManifest = _manifest(
      generation: 9,
      chapters: const <String>['c1', 'c2'],
    );
    await _putPlacement(indexPath, tree, newManifest);
    await _writeIntent(
      indexPath,
      tree: tree,
      operation: 'replace',
      oldPlacement: oldManifest,
      oldManifest: oldManifest,
      nextManifest: newManifest,
    );
    final io = _MemorySafIo(<String, Uint8List>{
      manifestPath: _encoded(newManifest),
      backupPath: _encoded(oldManifest),
    });

    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      indexPath: indexPath,
      safMirror: io,
      safTreeUri: tree,
    );
    addTearDown(store.close);

    expect(_decode(io.storage[manifestPath]!), _matches(newManifest));
    expect(io.storage.containsKey(backupPath), isFalse);
    expect(await _intentFiles(indexPath), isEmpty);
  });

  test('committed SAF target retires corrupt backup from explicit intent',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-saf-manifest-stale-');
    addTearDown(() => root.delete(recursive: true));
    final indexPath = '${root.path}/chapter_downloads.sqlite';
    final oldManifest = _manifest(generation: 11, chapters: const <String>['c1']);
    final committed = _manifest(
      generation: 12,
      chapters: const <String>['c1', 'c2'],
    );
    await _putPlacement(indexPath, tree, committed);
    await _writeIntent(
      indexPath,
      tree: tree,
      operation: 'replace',
      oldPlacement: oldManifest,
      oldManifest: oldManifest,
      nextManifest: committed,
    );
    final io = _MemorySafIo(<String, Uint8List>{
      manifestPath: _encoded(committed),
      backupPath: Uint8List.fromList(utf8.encode('{corrupt')),
    });

    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      indexPath: indexPath,
      safMirror: io,
      safTreeUri: tree,
    );
    addTearDown(store.close);

    expect(_decode(io.storage[manifestPath]!), _matches(committed));
    expect(io.storage.containsKey(backupPath), isFalse);
  });

  test('old SAF placement restores backup over corrupt uncommitted target',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-saf-manifest-corrupt-');
    addTearDown(() => root.delete(recursive: true));
    final indexPath = '${root.path}/chapter_downloads.sqlite';
    final committed = _manifest(generation: 14, chapters: const <String>['c1']);
    final next = _manifest(generation: 15, chapters: const <String>['c1', 'c2']);
    await _putPlacement(indexPath, tree, committed);
    await _writeIntent(
      indexPath,
      tree: tree,
      operation: 'replace',
      oldPlacement: committed,
      oldManifest: committed,
      nextManifest: next,
    );
    final io = _MemorySafIo(<String, Uint8List>{
      manifestPath: Uint8List.fromList(utf8.encode('{corrupt')),
      backupPath: _encoded(committed),
    });

    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      indexPath: indexPath,
      safMirror: io,
      safTreeUri: tree,
    );
    addTearDown(store.close);

    expect(_decode(io.storage[manifestPath]!), _matches(committed));
    expect(io.storage.containsKey(backupPath), isFalse);
  });

  test('uncommitted SAF manifest delete restores target from intent', () async {
    final root = await Directory.systemTemp.createTemp('zic-saf-manifest-delete-old-');
    addTearDown(() => root.delete(recursive: true));
    final indexPath = '${root.path}/chapter_downloads.sqlite';
    final committed = _manifest(generation: 20, chapters: const <String>['c1']);
    await _putPlacement(indexPath, tree, committed);
    await _writeIntent(
      indexPath,
      tree: tree,
      operation: 'delete',
      oldPlacement: committed,
      oldManifest: committed,
    );
    final io = _MemorySafIo(<String, Uint8List>{
      backupPath: _encoded(committed),
    });

    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      indexPath: indexPath,
      safMirror: io,
      safTreeUri: tree,
    );
    addTearDown(store.close);

    expect(_decode(io.storage[manifestPath]!), _matches(committed));
    expect(io.storage.containsKey(backupPath), isFalse);
    expect(await _intentFiles(indexPath), isEmpty);
  });

  test('committed SAF manifest delete retires backup from intent', () async {
    final root = await Directory.systemTemp.createTemp('zic-saf-manifest-delete-new-');
    addTearDown(() => root.delete(recursive: true));
    final indexPath = '${root.path}/chapter_downloads.sqlite';
    final committed = _manifest(generation: 21, chapters: const <String>['c1']);
    await _createIndex(indexPath);
    await _writeIntent(
      indexPath,
      tree: tree,
      operation: 'delete',
      oldPlacement: committed,
      oldManifest: committed,
    );
    final io = _MemorySafIo(<String, Uint8List>{
      backupPath: _encoded(committed),
    });

    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      indexPath: indexPath,
      safMirror: io,
      safTreeUri: tree,
    );
    addTearDown(store.close);

    expect(io.storage.containsKey(manifestPath), isFalse);
    expect(io.storage.containsKey(backupPath), isFalse);
    expect(await _intentFiles(indexPath), isEmpty);
  });

  test('SAF manifest replacement commits placement without atomic replace',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-saf-manifest-write-');
    addTearDown(() => root.delete(recursive: true));
    final indexPath = '${root.path}/chapter_downloads.sqlite';
    final oldManifest = _manifest(generation: 2, chapters: const <String>['c1']);
    await _putPlacement(indexPath, tree, oldManifest);
    final io = _MemorySafIo(<String, Uint8List>{
      manifestPath: _encoded(oldManifest),
    });
    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      indexPath: indexPath,
      safMirror: io,
      safTreeUri: tree,
    );
    addTearDown(store.close);

    await store.writeComicFolderManifest(
      _entry(chapterId: 'c2'),
      comicDirectoryName: 'Comic',
      knownChapterIds: const <String>['c1'],
    );

    final committed = _decode(io.storage[manifestPath]!);
    final placement = await store.index.getPlacement(
      sourceId: 'source',
      comicId: 'comic',
    );
    expect(committed.chapters, containsAll(<String>['c1', 'c2']));
    // Recovery's old-generation read is reused; retain the independent read
    // of the installed generation before publishing placement authority.
    expect(io.manifestGenerationsRead.where((value) => value == 2), hasLength(4));
    expect(io.manifestGenerationsRead.where((value) => value == committed.generation),
      hasLength(1));
    expect(placement?.generation, committed.generation);
    expect(placement?.fingerprint, committed.fingerprint);
    expect(io.storage.containsKey(backupPath), isFalse);
    expect(await _intentFiles(indexPath), isEmpty);
  });

  test('last SAF chapter removal commits manifest deletion through placement',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-saf-manifest-delete-live-');
    addTearDown(() => root.delete(recursive: true));
    final indexPath = '${root.path}/chapter_downloads.sqlite';
    final manifest = _manifest(generation: 30, chapters: const <String>['c1']);
    await _putPlacement(indexPath, tree, manifest);
    final io = _MemorySafIo(<String, Uint8List>{
      manifestPath: _encoded(manifest),
    });
    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      indexPath: indexPath,
      safMirror: io,
      safTreeUri: tree,
    );
    addTearDown(store.close);

    await store.removeChapterFromComicFolderManifest(
      _entry(chapterId: 'c1'),
      comicDirectoryName: 'Comic',
    );

    expect(io.storage.containsKey(manifestPath), isFalse);
    expect(io.storage.containsKey(backupPath), isFalse);
    expect(
      await store.index.getPlacement(sourceId: 'source', comicId: 'comic'),
      isNull,
    );
    expect(await _intentFiles(indexPath), isEmpty);
  });
}

ComicFolderManifest _manifest({
  required int generation,
  required List<String> chapters,
}) {
  final draft = ComicFolderManifest(
    sourceId: 'source',
    comicId: 'comic',
    comicTitle: 'Comic',
    chapters: chapters,
    generation: generation,
    updatedAt: DateTime.utc(2026, 9, 29, 12, generation),
  );
  return draft.copyWith(fingerprint: draft.computedFingerprint);
}

Uint8List _encoded(ComicFolderManifest manifest) =>
    Uint8List.fromList(utf8.encode(manifest.encode()));

ComicFolderManifest _decode(Uint8List bytes) =>
    ComicFolderManifest.decode(utf8.decode(bytes))!;

Matcher _matches(ComicFolderManifest manifest) => allOf(
      isA<ComicFolderManifest>(),
      predicate<ComicFolderManifest>(
        (value) =>
            value.generation == manifest.generation &&
            value.fingerprint == manifest.fingerprint &&
            value.chapters.join('|') == manifest.chapters.join('|'),
      ),
    );

Future<void> _createIndex(String indexPath) async {
  final index = SqliteIndex(indexPath);
  await index.open();
  await index.close();
}

Future<List<FileSystemEntity>> _intentFiles(String indexPath) async {
  final directory = Directory('$indexPath.saf-manifest-transactions');
  if (!await directory.exists()) return const <FileSystemEntity>[];
  return directory.list(followLinks: false).toList();
}

Future<void> _writeIntent(
  String indexPath, {
  required String tree,
  required String operation,
  required ComicFolderManifest oldPlacement,
  required ComicFolderManifest? oldManifest,
  ComicFolderManifest? nextManifest,
}) async {
  final directory = Directory('$indexPath.saf-manifest-transactions');
  await directory.create(recursive: true);
  final payload = <String, Object?>{
    'version': 1,
    'operation': operation,
    'treeUri': tree,
    'manifestPath': 'Comic/$comicManifestFileName',
    'sourceId': 'source',
    'comicId': 'comic',
    'oldPlacementGeneration': oldPlacement.generation,
    'oldPlacementFingerprint': oldPlacement.fingerprint,
    'hadTarget': oldManifest != null,
    'oldManifestGeneration': oldManifest?.generation,
    'oldManifestFingerprint': oldManifest?.fingerprint,
    'newGeneration': nextManifest?.generation,
    'newFingerprint': nextManifest?.fingerprint,
  };
  await File('${directory.path}/txn-test.json').writeAsString(
    jsonEncode(payload),
    flush: true,
  );
}

Future<void> _putPlacement(
  String indexPath,
  String tree,
  ComicFolderManifest manifest,
) async {
  final index = SqliteIndex(indexPath);
  await index.open();
  try {
    await index.putPlacement(
      DownloadPlacement(
        placementId: 'source\u0000comic',
        sourceId: 'source',
        comicId: 'comic',
        comicTitle: 'Comic',
        mode: DownloadPlacementMode.incremental,
        relativeDirectory: 'Comic',
        storageRootId: tree,
        generation: manifest.generation,
        fingerprint: manifest.fingerprint,
        createdAt: DateTime.utc(2026, 9, 29),
        updatedAt: DateTime.utc(2026, 9, 29),
      ),
    );
  } finally {
    await index.close();
  }
}

ImportedLibraryEntry _entry({required String chapterId}) => ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'source:comic:$chapterId',
        displayName: 'Chapter $chapterId',
        sourceId: 'source',
        comicId: 'comic',
        comicTitle: 'Comic',
        chapterId: chapterId,
        sourceRevision: 'r1',
        sequence: chapterId == 'c1' ? 1 : 2,
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'https://example.test/page.webp',
            pageId: 'p1',
            contentKindHint: ContentKindHint.webp,
          ),
        ],
      ),
    );

final class _MemorySafIo implements SafTreeIo {
  _MemorySafIo(this.storage);

  final Map<String, Uint8List> storage;
  final List<String> existsCalls = <String>[];
  final List<int> manifestGenerationsRead = <int>[];
  final Map<int, ({String path, int position})> _handles =
      <int, ({String path, int position})>{};
  int _nextHandle = 1;

  @override
  Future<int?> open(
    String relativePath, {
    SafWriteMode mode = SafWriteMode.read,
  }) async {
    if (mode == SafWriteMode.read && !storage.containsKey(relativePath)) {
      return null;
    }
    if (mode == SafWriteMode.read && relativePath.endsWith('/$comicManifestFileName')) {
      final manifest = ComicFolderManifest.decode(utf8.decode(storage[relativePath]!));
      if (manifest != null) manifestGenerationsRead.add(manifest.generation);
    }
    if (mode == SafWriteMode.writeTruncate) {
      storage[relativePath] = Uint8List(0);
    } else if (mode == SafWriteMode.writeAppend) {
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
    final builder = BytesBuilder(copy: false)
      ..add(current.sublist(0, state.position))
      ..add(bytes);
    storage[state.path] = builder.takeBytes();
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
  Future<bool> exists(String relativePath) async {
    existsCalls.add(relativePath);
    return storage.containsKey(relativePath);
  }

  @override
  Future<List<SafTreeFile>> list(String relativePath) async {
    final prefix = relativePath.isEmpty ? '' : '$relativePath/';
    return <SafTreeFile>[
      for (final entry in storage.entries)
        if (entry.key.startsWith(prefix) &&
            !entry.key.substring(prefix.length).contains('/'))
          SafTreeFile(
            name: entry.key.substring(prefix.length),
            isDirectory: false,
            length: entry.value.lengthInBytes,
          ),
    ];
  }
}

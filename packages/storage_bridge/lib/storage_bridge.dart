import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:storage/storage.dart';

export 'package:storage/storage.dart'
    show
        CacheLayout,
        DirectStorageAccessLocator,
        SafStorageAccessLocator,
        StorageRootAccessAliasProof,
        StorageRootAliasProbeIo,
        proveStorageRootAccessAlias,
        ChapterDownloadStoreMoveReport,
        LazyImportedLibraryStore,
        HomeChapterDownloadSummary,
        HomeProjectionSnapshot,
        HomeProjectionSnapshotStore,
        buildComicDirectoryName,
        chapterDownloadStoreHasContent,
        defaultChapterDownloadDirectory,
        defaultChapterDownloadMetadataPath,
        legacyChapterDownloadMetadataPath,
        migrateLegacyChapterDownloadMetadata,
        isSameDirectoryPath,
        isSameOrNestedDirectoryPath,
        moveChapterDownloadStore,
        probeChapterDownloadDirectoryWritable,
        resolveChapterDownloadDirectory;

/// Builds the engine-facing provider for immutable encoded image content.
///
/// File-backed sources avoid materializing the whole encoded file in the Dart
/// heap on a warm start. The engine remains free to mmap or copy internally as
/// required by the platform decoder, so this is intentionally not advertised
/// as an absolute storage-to-texture zero-copy guarantee.
ImageProvider<Object> encodedResourceImageProvider(
  EncodedResourceSource source,
) =>
    switch (source) {
      MemoryEncodedResourceSource(
        :final bytes,
        :final cacheIdentity,
      ) =>
        cacheIdentity == null
            ? MemoryImage(bytes)
            : _IdentityMemoryImage(bytes, cacheIdentity),
      FileEncodedResourceSource(
        :final path,
        :final cacheIdentity,
      ) =>
        cacheIdentity == null
            ? FileImage(File(path))
            : _IdentityFileImage(File(path), cacheIdentity),
    };

abstract interface class _IdentityEncodedImageProvider {
  Object get cacheIdentity;
  double get scale;
}

bool _sameEncodedImageIdentity(
  _IdentityEncodedImageProvider self,
  Object other,
) =>
    other is _IdentityEncodedImageProvider &&
    other.scale == self.scale &&
    other.cacheIdentity == self.cacheIdentity;

int _encodedImageIdentityHash(_IdentityEncodedImageProvider provider) =>
    Object.hash(
      _IdentityEncodedImageProvider,
      provider.scale,
      provider.cacheIdentity,
    );

final class _IdentityMemoryImage extends MemoryImage
    implements _IdentityEncodedImageProvider {
  const _IdentityMemoryImage(super.bytes, this.cacheIdentity);

  @override
  final Object cacheIdentity;

  @override
  bool operator ==(Object other) => _sameEncodedImageIdentity(this, other);

  @override
  int get hashCode => _encodedImageIdentityHash(this);
}

final class _IdentityFileImage extends FileImage
    implements _IdentityEncodedImageProvider {
  const _IdentityFileImage(super.file, this.cacheIdentity);

  @override
  final Object cacheIdentity;

  @override
  bool operator ==(Object other) => _sameEncodedImageIdentity(this, other);

  @override
  int get hashCode => _encodedImageIdentityHash(this);
}

/// Materializes immutable encoded content behind the platform/storage boundary.
///
/// App composition should not open durable cache files directly; it consumes
/// [EncodedResourceSource] while this bridge owns the file-system conversion.
Future<Uint8List> readEncodedResourceBytes(EncodedResourceSource source) =>
    switch (source) {
      MemoryEncodedResourceSource(:final bytes) => Future<Uint8List>.value(bytes),
      FileEncodedResourceSource(:final path) => File(path).readAsBytes(),
    };

/// Reads only a bounded encoded prefix from a file-backed presentation source.
///
/// Descriptor paths such as `/proc/self/fd/<n>` can share their open-file
/// offset with the pinned platform descriptor. Restore position zero before
/// releasing the temporary Dart reader so a later engine reopen sees the
/// encoded body from byte zero. I/O failure is an optimization miss: callers
/// can release the file lease and fall back to their existing byte path.
Future<Uint8List?> tryReadEncodedFilePrefix(
  FileEncodedResourceSource source, {
  required int maxBytes,
}) async {
  if (maxBytes <= 0) {
    throw ArgumentError.value(maxBytes, 'maxBytes', 'must be positive');
  }
  RandomAccessFile? reader;
  try {
    reader = await File(source.path).open(mode: FileMode.read);
    final expectedLength = source.lengthInBytes;
    final readLength = expectedLength == null || expectedLength > maxBytes
        ? maxBytes
        : expectedLength;
    final prefix = await reader.read(readLength);
    await reader.setPosition(0);
    await reader.close();
    reader = null;
    return prefix;
  } on FileSystemException {
    if (reader != null) {
      try {
        await reader.close();
      } on FileSystemException {
        // The platform presentation lease remains the outer owner.
      }
    }
    return null;
  }
}

Future<String> getDefaultZicStorageRoot({
  Future<String?> Function()? applicationSupportPath,
}) async {
  final supportPath = await applicationSupportPath?.call() ??
      (await getApplicationSupportDirectory()).path;
  return '$supportPath/zic';
}

ImportedLibraryStore createLazyImportedLibraryStore({
  required Future<String> Function() storageRoot,
}) =>
    LazyImportedLibraryStore(rootProvider: storageRoot);

HomeProjectionSnapshotStore createHomeProjectionSnapshotStore({
  required Future<String> Function() storageRoot,
}) =>
    HomeProjectionSnapshotStore(rootProvider: storageRoot);

/// Returns whether the installation already has durable application state.
///
/// A fresh install must not create the imported-library, offline-cache, or
/// Home projection snapshot files just because Home was opened. Existing state
/// still includes a queue or snapshot file because restoring either projection
/// requires the durable composition to reconcile it.
///
/// [chapterDownloadDirectory] is used only to detect a pre-migration legacy
/// `cache.sqlite`; current chapter metadata lives under [storageRoot].
Future<bool> durableZicStateExists(
  String storageRoot, {
  String? chapterDownloadDirectory,
}) async {
  final importedLibrary = File('$storageRoot/imported_library.sqlite3');
  final chapterMetadata = File(defaultChapterDownloadMetadataPath(storageRoot));
  final effectiveDownloadDirectory = chapterDownloadDirectory ??
      defaultChapterDownloadDirectory(storageRoot);
  final legacyChapterMetadata = File(
    legacyChapterDownloadMetadataPath(
      storageRoot: storageRoot,
      downloadDirectory: effectiveDownloadDirectory,
    ),
  );
  final wholeComicQueue = File('$storageRoot/whole_comic_queue.json');
  final homeSnapshot = File('$storageRoot/home_projection_snapshot.json');
  // A completed Home snapshot is itself durable application state. Checking
  // it first avoids probing the large SQLite/cache files on the hot startup
  // path; the durable open below still validates the authoritative stores.
  if (await homeSnapshot.exists()) {
    print(
      '[zic-storage] durable-state-files '
      'library=unknown chapterMetadata=unknown legacyChapterMetadata=unknown '
      'wholeComicQueue=unknown '
      'homeSnapshot=true source=home-snapshot',
    );
    return true;
  }
  final results = await Future.wait<bool>(<Future<bool>>[
    importedLibrary.exists(),
    chapterMetadata.exists(),
    legacyChapterMetadata.exists(),
    wholeComicQueue.exists(),
  ]);
  print(
    '[zic-storage] durable-state-files '
    'library=${results[0]} chapterMetadata=${results[1]} '
    'legacyChapterMetadata=${results[2]} wholeComicQueue=${results[3]} '
    'homeSnapshot=false source=full-scan',
  );
  return results.any((exists) => exists);
}

ResourceCacheCoordinator createAppResourceCache({
  required String storageRoot,
  ResourceCacheManager? responses,
  ArtifactCacheMaintenance? artifacts,
  void Function(Object error, StackTrace stackTrace)? onPersistenceError,
}) {
  return ResourceCacheCoordinator(
    responses: responses ??
        ResourceCacheManager(
          byteStore: FileResourceCacheByteStore(
            '$storageRoot/resource_cache/responses',
          ),
          onPersistenceError: onPersistenceError,
        ),
    artifacts: artifacts,
  );
}

/// Returns whether [directory] holds an opened-before chapter-download store
/// index. Composition code consumes this probe instead of touching `dart:io`.
Future<bool> chapterDownloadIndexExists(String directory) =>
    File('$directory/cache.sqlite').exists();

Future<bool> chapterDownloadMetadataExists(String storageRoot) =>
    File(defaultChapterDownloadMetadataPath(storageRoot)).exists();

/// Completes a deferred or interrupted chapter-download store move and
/// returns the effective chapter-download directory for this launch.
///
/// The settings flow records the intended target plus the previous store
/// location before touching any bytes, so a crash mid-move is repaired here,
/// before any service opens the stores. A move failure is propagated to the
/// startup caller, which may still open the target in degraded mode while
/// retaining the pending marker for the next retry.
Future<String> settleChapterDownloadDirectory({
  required String storageRoot,
  required String? configuredOverride,
  String? pendingMoveFrom,
  String? metadataDbPath,
}) async {
  final defaultDirectory = defaultChapterDownloadDirectory(storageRoot);
  final target = configuredOverride ?? defaultDirectory;
  final separator = Platform.pathSeparator;
  bool samePath(String a, String b) {
    String strip(String value) {
      var result = value;
      while (result.length > 1 && result.endsWith(separator)) {
        result = result.substring(0, result.length - 1);
      }
      return result;
    }

    return strip(a) == strip(b);
  }

  if (pendingMoveFrom != null &&
      !samePath(pendingMoveFrom, target) &&
      (chapterDownloadStoreHasContent(pendingMoveFrom) ||
          chapterDownloadStoreHasContent(target))) {
    final report = await moveChapterDownloadStore(
      from: pendingMoveFrom,
      to: target,
      metadataDbPath: metadataDbPath,
    );
    print(
      '[zic-storage] chapter-download move completed '
      'from=$pendingMoveFrom to=$target files=${report.movedFileCount} '
      'records=${report.rewrittenRecordCount}',
    );
  } else if (!target.startsWith('saf://') &&
      metadataDbPath == null &&
      !samePath(defaultDirectory, target) &&
      chapterDownloadStoreHasContent(defaultDirectory) &&
      !await File('$target/cache.sqlite').exists()) {
    // Legacy pre-private-metadata recovery: an override is configured while
    // the default location still owns the only indexed store (for example a
    // crash before the move started). Once App-private metadata exists, root
    // content is no longer sufficient evidence to infer an automatic move.
    // Bring the legacy store to the configured location. Let failures
    // reach startup so the pending intent remains durable and the source can
    // be reopened as the authoritative recovery side.
    final report = await moveChapterDownloadStore(
      from: defaultDirectory,
      to: target,
      metadataDbPath: metadataDbPath,
    );
    print(
      '[zic-storage] chapter-download default-location adoption completed '
      'to=$target files=${report.movedFileCount} '
      'records=${report.rewrittenRecordCount}',
    );
  }
  return target;
}

Future<ImportedLibraryStore> openDefaultImportedLibraryStore() async {
  final root = await getDefaultZicStorageRoot();
  return openImportedLibraryStore(root);
}

Future<ImportedLibraryStore> openImportedLibraryStore(String storageRoot) async {
  final store = SqliteImportedLibraryStore(
    '$storageRoot/imported_library.sqlite3',
  );
  await store.open();
  return store;
}

Future<Map<String, Object?>?> readJsonObjectFile(String path) async {
  final file = File(path);
  if (!await file.exists()) {
    return null;
  }
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map<Object?, Object?>) {
    throw const FormatException('JSON document root must be an object');
  }
  return decoded.cast<String, Object?>();
}

Future<void> writeJsonObjectFile(
  String path,
  Map<String, Object?> data,
) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  final temporary = File(
    '$path.tmp-${DateTime.now().microsecondsSinceEpoch}',
  );
  try {
    await temporary.writeAsString(jsonEncode(data), flush: true);
    // POSIX/Android rename replaces the directory entry atomically. Never
    // delete the previous queue/preferences authority first: if the commit
    // cannot be completed, readers keep the last complete JSON document.
    await temporary.rename(path);
  } finally {
    if (await temporary.exists()) {
      await temporary.delete();
    }
  }
}

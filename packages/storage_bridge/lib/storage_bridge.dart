import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:storage/storage.dart';

export 'package:storage/storage.dart'
    show HomeProjectionSnapshot, HomeProjectionSnapshotStore;

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
      MemoryEncodedResourceSource(:final bytes) => MemoryImage(bytes),
      FileEncodedResourceSource(:final path) => FileImage(File(path)),
    };

/// Materializes immutable encoded content behind the platform/storage boundary.
///
/// App composition should not open durable cache files directly; it consumes
/// [EncodedResourceSource] while this bridge owns the file-system conversion.
Future<Uint8List> readEncodedResourceBytes(EncodedResourceSource source) =>
    switch (source) {
      MemoryEncodedResourceSource(:final bytes) => Future<Uint8List>.value(bytes),
      FileEncodedResourceSource(:final path) => File(path).readAsBytes(),
    };

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
Future<bool> durableZicStateExists(String storageRoot) async {
  final importedLibrary = File('$storageRoot/imported_library.sqlite3');
  final offlineCache = File('$storageRoot/offline_chapters/cache.sqlite');
  final wholeComicQueue = File('$storageRoot/whole_comic_queue.json');
  final homeSnapshot = File('$storageRoot/home_projection_snapshot.json');
  // A completed Home snapshot is itself durable application state. Checking
  // it first avoids probing the large SQLite/cache files on the hot startup
  // path; the durable open below still validates the authoritative stores.
  if (await homeSnapshot.exists()) {
    print(
      '[zic-storage] durable-state-files '
      'library=unknown offlineCache=unknown wholeComicQueue=unknown '
      'homeSnapshot=true source=home-snapshot',
    );
    return true;
  }
  final results = await Future.wait<bool>(<Future<bool>>[
    importedLibrary.exists(),
    offlineCache.exists(),
    wholeComicQueue.exists(),
    homeSnapshot.exists(),
  ]);
  print(
    '[zic-storage] durable-state-files '
    'library=${results[0]} offlineCache=${results[1]} '
    'wholeComicQueue=${results[2]} homeSnapshot=${results[3]} source=full-scan',
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
  final temporary = File('$path.tmp');
  await temporary.writeAsString(jsonEncode(data), flush: true);
  if (await file.exists()) {
    await file.delete();
  }
  await temporary.rename(path);
}

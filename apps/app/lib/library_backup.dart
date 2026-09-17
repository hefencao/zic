import 'dart:convert';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:file_selector/file_selector.dart';

Future<Map<String, Object?>> buildImportedLibraryBackup(
  ImportedLibraryStore store,
) async {
  final snapshotStore = store is ImportedLibraryBackupSnapshotStore
      ? store as ImportedLibraryBackupSnapshotStore
      : null;
  final snapshot = snapshotStore != null
      ? await snapshotStore.readLibraryBackupSnapshot()
      : await _readLegacyBackupSnapshot(store);
  final now = DateTime.now().toUtc();
  return <String, Object?>{
    'format': 'zic-library-backup-v1',
    'createdAt': now.toIso8601String(),
    'chapters': <Map<String, Object?>>[
      for (final entry in snapshot.entries)
        <String, Object?>{
          'chapter': entry.chapter.toJson(),
          if (entry.progress != null) 'progress': entry.progress!.toJson(),
        },
    ],
    'savedComics': snapshot.savedComics.map((value) => value.toJson()).toList(),
    'categories': snapshot.categories.map((value) => value.toJson()).toList(),
    'comicPreferences':
        snapshot.comicPreferences.map((value) => value.toJson()).toList(),
    'chapterReadStates':
        snapshot.chapterReadStates.map((value) => value.toJson()).toList(),
    'sourcePreferences':
        snapshot.sourcePreferences.map((value) => value.toJson()).toList(),
    'migrationIssues':
        snapshot.migrationIssues.map((value) => value.toJson()).toList(),
  };
}

Future<ImportedLibraryBackupSnapshot> _readLegacyBackupSnapshot(
  ImportedLibraryStore store,
) async {
  final checkpointStore = store is ReaderProgressCheckpointStore
      ? store as ReaderProgressCheckpointStore
      : null;
  if (checkpointStore != null) {
    await checkpointStore.flushProgressCheckpoints();
  }
  return ImportedLibraryBackupSnapshot(
    entries: await store.list(),
    savedComics: await store.listSavedComics(),
    categories: await store.listCategories(),
    comicPreferences: await store.listComicPreferences(),
    chapterReadStates: await store.listAllChapterReadStates(),
    sourcePreferences: await store.listSourcePreferences(),
    migrationIssues: await store.listMigrationIssues(includeAcknowledged: true),
  );
}

Future<String?> exportImportedLibraryBackup(ImportedLibraryStore store) async {
  final payload = await buildImportedLibraryBackup(store);
  final createdAt = DateTime.parse(payload['createdAt'] as String);
  final date = createdAt.toIso8601String().replaceAll(':', '-').split('.').first;
  final name = 'zic-backup-$date.json';
  final location = await getSaveLocation(suggestedName: name);
  if (location == null) return null;
  final encoded = const JsonEncoder.withIndent('  ').convert(payload);
  final bytes = Uint8List.fromList(utf8.encode(encoded));
  await XFile.fromData(
    bytes,
    mimeType: 'application/json',
    name: name,
  ).saveTo(location.path);
  return location.path;
}

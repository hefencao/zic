import 'dart:convert';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:file_selector/file_selector.dart';

Future<Map<String, Object?>> buildImportedLibraryBackup(
  ImportedLibraryStore store,
) async {
  final entries = await store.list();
  final savedComics = await store.listSavedComics();
  final categories = await store.listCategories();
  final preferences = await store.listComicPreferences();
  final readStates = await store.listAllChapterReadStates();
  final sourcePreferences = await store.listSourcePreferences();
  final migrationIssues = await store.listMigrationIssues(
    includeAcknowledged: true,
  );
  final now = DateTime.now().toUtc();
  return <String, Object?>{
    'format': 'zic-library-backup-v1',
    'createdAt': now.toIso8601String(),
    'chapters': <Map<String, Object?>>[
      for (final entry in entries)
        <String, Object?>{
          'chapter': entry.chapter.toJson(),
          if (entry.progress != null) 'progress': entry.progress!.toJson(),
        },
    ],
    'savedComics': savedComics.map((value) => value.toJson()).toList(),
    'categories': categories.map((value) => value.toJson()).toList(),
    'comicPreferences': preferences.map((value) => value.toJson()).toList(),
    'chapterReadStates': readStates.map((value) => value.toJson()).toList(),
    'sourcePreferences':
        sourcePreferences.map((value) => value.toJson()).toList(),
    'migrationIssues': migrationIssues.map((value) => value.toJson()).toList(),
  };
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

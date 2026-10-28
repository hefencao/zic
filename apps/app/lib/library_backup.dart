import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:network_bridge/network_bridge.dart';

import 'app_preferences.dart';
import 'library_sync.dart';
import 'portable_settings.dart';

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

Future<String?> exportImportedLibraryBackup(ImportedLibraryStore store, {
  Future<Map<String, LibrarySyncRecord>> Function()? readRecords,
}) async {
  final payload = readRecords == null ? await buildImportedLibraryBackup(store) : null;
  final records = await readRecords?.call();
  final createdAt = payload == null ? DateTime.now().toUtc()
      : DateTime.parse(payload['createdAt'] as String);
  final date = createdAt.toIso8601String().replaceAll(':', '-').split('.').first;
  final name = 'zic-backup-$date.json' + (records == null ? '' : '.gz');
  final bytes = records == null
      ? Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(payload)))
      : await Isolate.run(() => Uint8List.fromList(const MetadataGzipCodec().encode(
          encodeLibrarySync(records, compress: false))));
  final mimeType = records == null ? 'application/json' : 'application/gzip';
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return const MethodChannel('dev.zic.zic/document_export')
        .invokeMethod<String>('saveDocument', <String, Object?>{
      'suggestedName': name,
      'mimeType': mimeType,
      'bytes': bytes,
    });
  }
  final location = await getSaveLocation(suggestedName: name);
  if (location == null) return null;
  await XFile.fromData(
    bytes,
    mimeType: mimeType,
    name: name,
  ).saveTo(location.path);
  return location.path;
}

/// Decoding is complete and validated before preview; choosing/cancelling a
/// document cannot mutate either the library or the synchronization journal.
Future<Map<String, LibrarySyncRecord>> readImportedLibraryBackup(XFile file) async {
  // Android's selector copies the document to a readable local path, but its
  // in-memory bytes are sized from provider metadata, which can still be zero.
  final input = !kIsWeb && defaultTargetPlatform == TargetPlatform.android && file.path.isNotEmpty
      ? XFile(file.path) : file;
  final length = await input.length();
  if (length > maxLibrarySyncBytes) {
    throw const LibrarySyncFormatException('备份文件超过 32 MiB');
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in input.openRead()) {
    if (builder.length + chunk.length > maxLibrarySyncBytes) {
      throw const LibrarySyncFormatException('备份文件超过 32 MiB');
    }
    builder.add(chunk);
  }
  final bytes = builder.takeBytes();
  return Isolate.run(() => decodeImportedLibraryBackup(bytes));
}

Map<String, LibrarySyncRecord> decodeImportedLibraryBackup(List<int> bytes) {
  if (bytes.length > maxLibrarySyncBytes) {
    throw const LibrarySyncFormatException('备份文件超过 32 MiB');
  }
  final List<int> plain;
  try {
    plain = bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b
        ? const MetadataGzipCodec().decode(bytes, maxBytes: maxLibrarySyncBytes) : bytes;
  } on MetadataGzipLimitException {
    throw const LibrarySyncFormatException('备份解压后超过 32 MiB');
  }
  final raw = jsonDecode(utf8.decode(plain));
  final Map<String, LibrarySyncRecord> records;
  if (raw is Map && raw['format'] == 'zic-library-backup-v1') {
    List<T> section<T>(String name, T Function(Map<String, Object?>) decode) {
      final list = raw[name] ?? const [];
      if (list is! List || list.length > maxLibrarySyncRecords) {
        throw const LibrarySyncFormatException('无效的备份记录列表');
      }
      return [for (final value in list) decode(Map<String, Object?>.from(value as Map))];
    }
    final snapshot = ImportedLibraryBackupSnapshot(
      entries: section('chapters', (data) => ImportedLibraryEntry(
        chapter: ImportedChapterRecord.fromJson(Map<String, Object?>.from(data['chapter']! as Map)),
        progress: data['progress'] == null ? null : ReadingProgress.fromJson(
          Map<String, Object?>.from(data['progress']! as Map)))),
      savedComics: section('savedComics', SavedComicRecord.fromJson),
      categories: section('categories', LibraryCategory.fromJson),
      comicPreferences: section('comicPreferences', ComicPreference.fromJson),
      chapterReadStates: section('chapterReadStates', ChapterReadState.fromJson),
      sourcePreferences: section('sourcePreferences', ComicSourcePreference.fromJson),
      migrationIssues: const [],
    );
    final values = buildLibrarySyncValues(snapshot, const {});
    final count = snapshot.savedComics.length + snapshot.categories.length +
        snapshot.comicPreferences.length + snapshot.chapterReadStates.length + snapshot.sourcePreferences.length +
        snapshot.entries.fold<int>(0, (sum, entry) => sum +
          (isLocalLibrarySource(entry.chapter.sourceId) || entry.chapter.isSummary ? 0 : 1) +
          (entry.progress == null ? 0 : 1));
    if (values.length != count) {
      throw const LibrarySyncFormatException('备份包含重复或不可迁移的记录');
    }
    records = {for (final entry in values.entries) entry.key: LibrarySyncRecord.fromJson({
      'key': entry.key, 'time': entry.value.initialTime, 'writer': 'manual-backup', 'data': entry.value.data,
    })};
  } else {
    records = decodeLibrarySync(plain);
  }
  for (final record in records.values) {
    if (record.kind == 'reader' && record.data != null) {
      AppPreferencesController.validateSyncReadingSettings(record.identity, record.data!);
    } else if (record.kind == 'setting') {
      PortableSettingsOwner.validate(record.key, record.data);
    }
  }
  return records;
}

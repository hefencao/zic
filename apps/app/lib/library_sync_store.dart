import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';

import 'library_sync.dart';

Future<ImportedLibraryBackupSnapshot> readLibrarySyncSnapshot(
  ImportedLibraryStore store,
) {
  if (store is! ImportedLibraryBackupSnapshotStore) {
    throw StateError('library does not support consistent synchronization');
  }
  return (store as ImportedLibraryBackupSnapshotStore).readLibraryBackupSnapshot();
}

/// Applies validated metadata through the current library owner. Each change
/// rechecks its exact local value; edits made during HTTP waits win locally.
/// Partial I/O failures are safe to replay on the next synchronization.
Future<void> applyLibrarySyncRecords(
  ImportedLibraryStore store,
  List<LibrarySyncRecord> changes,
  Map<String, LibrarySyncValue> expected,
) async {
  const order = <String, int>{
    'category': 0, 'comic': 1, 'chapter': 2,
    'preference': 3, 'read': 4, 'progress': 5, 'source': 0,
  };
  final sorted = changes.toList()
    ..sort((a, b) {
      final left = a.kind == 'category' && a.deleted ? 6 : order[a.kind]!;
      final right = b.kind == 'category' && b.deleted ? 6 : order[b.kind]!;
      return left.compareTo(right);
    });
  var count = 0;
  for (final record in sorted) {
    validateSyncRecord(record);
    final parts = record.parts;
    final data = record.data;
    final baseline = expected[record.key]?.data;
    Object? current;
    switch (record.kind) {
      case 'category':
        for (final value in await store.listCategories()) {
          if (value.categoryId == record.identity) current = value.toJson();
        }
      case 'comic':
        final comic = await store.getSavedComic(parts[0], parts[1]);
        if (comic != null) {
          current = buildLibrarySyncValues(_snapshot(comics: [comic]), const {})
              [record.key]?.data;
        }
      case 'chapter':
        final entry = await store.get(parts[0], parts[1]);
        if (entry != null) {
          current = buildLibrarySyncValues(_snapshot(entries: [entry]), const {})
              [record.key]?.data;
        }
      case 'progress':
        final progress = store is ImportedLibraryProgressLookup
            ? await (store as ImportedLibraryProgressLookup)
                .getProgress(parts[0], parts[1])
            : (await store.get(parts[0], parts[1]))?.progress;
        current = progress?.toJson();
      case 'preference':
        current = (await store.getComicPreference(parts[0], parts[1]))?.toJson();
      case 'read':
        final comicId = data?['comicId'] ?? baseline?['comicId'];
        if (comicId is String) {
          for (final value in await store.listChapterReadStates(parts[0], comicId)) {
            if (value.chapterId == parts[1]) current = value.toJson();
          }
        }
      case 'source':
        for (final value in await store.listSourcePreferences()) {
          if (value.sourceId == record.identity) current = value.toJson();
        }
    }
    if (syncFingerprint(current) != syncFingerprint(baseline)) continue;
    if (syncFingerprint(current) == record.fingerprint) continue;
    if (data == null) {
      switch (record.kind) {
        case 'category':
          await store.removeCategory(record.identity);
        case 'comic':
          await store.removeSavedComic(parts[0], parts[1]);
        case 'chapter':
          await store.removeChapter(parts[0], parts[1]);
        default:
          if (store is! ImportedLibrarySyncDeletionStore) {
            throw StateError('library does not support synchronized deletion');
          }
          final kind = switch (record.kind) {
            'progress' => LibrarySyncMetadataKind.progress,
            'preference' => LibrarySyncMetadataKind.preference,
            'read' => LibrarySyncMetadataKind.readState,
            _ => throw StateError('unknown metadata deletion'),
          };
          await (store as ImportedLibrarySyncDeletionStore).removeSyncedMetadata(
            kind, parts[0], parts[1],
            notAfter: DateTime.fromMicrosecondsSinceEpoch(record.time, isUtc: true),
          );
      }
    } else {
      switch (record.kind) {
        case 'category':
          await store.upsertCategory(LibraryCategory.fromJson(data));
        case 'comic':
          // Keep private/opaque artwork locators on their original device.
          var comic = SavedComicRecord.fromJson(data);
          final local = await store.getSavedComic(parts[0], parts[1]);
          if (!data.containsKey('coverSourceId') && local?.coverSourceId != null) {
            comic = comic.copyWith(coverSourceId: local!.coverSourceId);
          }
          await store.upsertSavedComic(comic);
        case 'chapter':
          var chapter = ImportedChapterRecord.fromJson(data);
          final local = (await store.get(parts[0], parts[1]))?.chapter;
          if (local != null) {
            final samePages = local.sourceRevision == chapter.sourceRevision &&
                local.pages.length == chapter.pages.length &&
                local.pages.asMap().entries.every((entry) =>
                  librarySyncPageIdentity(entry.value) ==
                    librarySyncPageIdentity(chapter.pages[entry.key]));
            chapter = ImportedChapterRecord.fromJson(<String, Object?>{
              ...data,
              if (samePages) 'pages': local.pages.map((page) => page.toJson()).toList(),
              if (!data.containsKey('coverSourceId') && local.coverSourceId != null)
                'coverSourceId': local.coverSourceId,
            });
          }
          await store.upsertChapter(chapter);
        case 'preference':
          await store.saveComicPreference(ComicPreference.fromJson(data));
        case 'read':
          await store.saveChapterReadState(ChapterReadState.fromJson(data));
        case 'progress':
          final chapter = await store.get(parts[0], parts[1]);
          // Local files are never synchronized. Their progress remains in the
          // cloud until this device has imported the matching local chapter.
          if (chapter == null) continue;
          final progress = ReadingProgress.fromJson(data);
          if (progress.comicId != chapter.chapter.comicId ||
              progress.pageIndex >= chapter.chapter.pages.length) continue;
          await store.saveProgress(progress);
        case 'source':
          await store.saveSourcePreference(ComicSourcePreference.fromJson(data));
      }
    }
    if (++count % 16 == 0) await Future<void>.delayed(Duration.zero);
  }
}

ImportedLibraryBackupSnapshot _snapshot({
  List<ImportedLibraryEntry> entries = const [],
  List<SavedComicRecord> comics = const [],
}) => ImportedLibraryBackupSnapshot(
  entries: entries, savedComics: comics, categories: const [],
  comicPreferences: const [], chapterReadStates: const [],
  sourcePreferences: const [], migrationIssues: const [],
);

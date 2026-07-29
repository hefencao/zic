# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.26.0-dev.30_migration-diagnostics-ui-reliability.zip`.
Do not merge or copy files from an earlier zic archive.

## Current implementation

- Home, Bookshelf and Comic Sources are the three primary destinations; remote browsing remains lazy.
- Details retain separate state owners with shared presentation components:
  - `RemoteComicDetailsScreen` owns live source catalogs and transient source failures.
  - `LocalComicDetailsScreen` owns saved comic metadata, persisted chapters/read state and offline state.
- `resolveComicDetailsRoute` uses exact `sourceId + comicId` durability. Whole-comic shelf/liked/
  collected/category actions persist `SavedComicRecord` and `ComicPreference`; chapter click reads and
  the chapter trailing action downloads.
- `ChapterDownloadService` publishes `ChapterDownloadSnapshot` task state with source-composite
  identity, page and byte progress, terminal phase and failure details.
- `PersistentChapterDownloadService` derives task state from the existing
  `DownloadRegistry -> DownloadSession -> promoted artifact` pipeline. It supports cancel, retry and
  offline artifact deletion; partial artifacts remain resumable and terminal state cannot be replaced
  by a late progress callback.
- Home, reading history and Bookshelf reuse `ComicCoverCard`. Incomplete downloads show a dimmed
  bottom-up waterline, percent and completed/total pages; complete comics show an unobtrusive offline
  badge. The Download Manager exposes per-chapter cancel/retry/delete and copyable errors.
- Offline deletion does not remove saved comics, imported chapter metadata, reading progress or read
  state.
- Cross-source migration remains explicit copy. It searches/selects a target, preflights every exact
  title+sequence chapter against a fresh target manifest before the first durable write, merges rather
  than overwrites target preferences, and only fills missing target progress/read state. Source URLs,
  offline bytes, existing target state and the original source are retained.
- SQLite schema version 6 keeps the source-composite library tables and adds durable acknowledgement
  timestamps to `library_migration_issue`. Schemas 1–4 upgrade transactionally, schema 5 upgrades in
  place, and acknowledgement never deletes or rewrites migration evidence.
- Missing cover data renders a stable placeholder rather than throwing during Widget build. Source and
  details errors remain selectable/copyable, and Android hosts receive `android.permission.INTERNET`
  through repository tooling.
- Bookshelf Migration Diagnostics lists pending or retained schema issues, exports JSON to the clipboard
  and supports individual/bulk acknowledgement. Reader controls fade at their final positions; local and
  remote chapter open/download work is isolated while the same manifest ensure is coalesced.

## Validation completed in this environment

```bash
python3 tool/check_repo.py
python3 tool/check_dart_structure.py
bash -n tool/*.sh
python3 -m py_compile tool/*.py
bash ./tool/check_native_header.sh
```

Additional delivery checks validate package versions, JSON/YAML/TOML syntax, archive cleanliness,
source-baseline patch reproducibility and a clean re-extraction. This container does not contain
Flutter, Dart, Cargo, Android SDK or Android NDK, so no claim is made that their tests or builds ran.

## Required external validation

```bash
flutter pub get
flutter test packages/domain/test/reading_progress_test.dart
flutter test packages/catalog/test/library_comic_test.dart
flutter test packages/catalog/test/imported_library_store_test.dart
flutter test packages/storage/test/imported_library_store_test.dart
flutter test packages/reader/test/reader_navigation_test.dart
flutter test apps/app/test/chapter_downloads_test.dart
flutter test apps/app/test/library_ui_test.dart
flutter test apps/app/test/source_browser_test.dart
flutter test apps/app/test/reader_controls_test.dart
flutter test apps/app/test/app_smoke_test.dart
bash ./tool/test_dart.sh
bash ./tool/test_flutter.sh
bash ./tool/analyze.sh
bash ./tool/check_native_header.sh
bash ./tool/check_webp.sh
bash ./tool/test_rust.sh
bash ./tool/build_android_native.sh release
bash ./tool/build_android.sh release
```

## Next mainline work

1. Add side-by-side migration candidate comparison (cover, authors, chapter counts and sampled titles)
   before confirmation; retain search/manual-ID selection and conservative chapter mapping.
2. Add source update ingestion and durable timestamps so Home updates reflect actual upstream changes.
3. Add source-specific typed settings for translation languages and data-saver mode.
4. Discover and manage orphaned offline artifacts whose chapter metadata was intentionally removed,
   without weakening DownloadSession ownership rules.
5. Define a sandboxed Mihon/Keiyoushi adapter ABI, permissions and lifecycle before loading extensions.

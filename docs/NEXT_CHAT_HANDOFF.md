# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.24.0-dev.28_source-composite-schema.zip`.
Do not merge or copy files from an earlier zic archive.

## Current implementation

- Home, Bookshelf and Comic Sources are the three primary destinations; remote browsing remains lazy.
- Details keep separate state owners with shared presentation components:
  - `RemoteComicDetailsScreen` owns the live source catalog and transient source failures.
  - `LocalComicDetailsScreen` owns saved comic metadata, persisted chapters/read state and offline state.
- `resolveComicDetailsRoute` uses exact `sourceId + comicId` durability. Whole-comic shelf/liked/
  collected/category actions persist `SavedComicRecord` and `ComicPreference`; chapter click reads and
  the chapter trailing action downloads.
- `PersistentChapterDownloadService` owns complete offline chapter artifacts and Reader reuses them
  after restart.
- Cross-source migration remains explicit copy. It searches/selects a target, preflights every exact
  title+sequence chapter against a fresh target manifest before the first durable write, merges rather
  than overwrites target preferences, and only fills missing target progress/read state. Source URLs,
  offline bytes, existing target state and the original source are retained.
- SQLite schema version 5 makes `imported_chapter`, `reading_progress`, `comic_preference` and
  `chapter_read_state` source-composite. Store point APIs, application maps and Widget keys use
  `sourceId + nativeId`, so different sources may safely reuse the same comic/chapter IDs.
- Schemas 1–4 upgrade transactionally. Legacy progress/read state inherits the imported chapter
  source. Ambiguous/orphaned legacy preference ownership is resolved deterministically and recorded
  in `library_migration_issue`, available through `listMigrationIssues()`. A foreign-key check must pass
  before the schema version is committed.
- Old JSON without `sourceId` is accepted only with an owning-source fallback; all current writes
  contain source identity.
- Generated Android hosts are configured by `tool/configure_platforms.py`, including
  `android.permission.INTERNET`.
- Source/details failures remain selectable and copyable. No IP pinning, certificate bypass, login,
  challenge solving or anti-bot bypass exists.

## Validation completed in this environment

```bash
python3 tool/check_repo.py
bash -n tool/*.sh
python3 -m py_compile tool/*.py
bash ./tool/check_native_header.sh
```

Additional delivery checks validate Dart delimiter balance, constructor/source-identity contracts,
test registration scope, SQL schema syntax, JSON/YAML/TOML parsing, package versions, archive
cleanliness and a clean re-extraction. This container does not contain Flutter, Dart, Cargo, Android
SDK or Android NDK, so no claim is made that their tests or builds ran here.

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

1. Add a download-management surface with per-chapter cancel/retry/delete, authoritative byte/page
   progress and cover waterline projection over `PersistentChapterDownloadService`.
2. Surface `library_migration_issue` in a non-intrusive library diagnostics view with copy/export and
   explicit acknowledgement; never auto-delete ambiguous source records.
3. Add side-by-side migration candidate comparison (cover, authors, chapter counts and sampled titles)
   before confirmation; retain search/manual-ID selection and conservative chapter mapping.
4. Add source update ingestion and durable timestamps so Home updates reflect actual upstream changes.
5. Add source-specific typed settings for translation languages and data-saver mode.
6. Define a sandboxed Mihon/Keiyoushi adapter ABI, permissions and lifecycle before loading extensions.

# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.23.0-dev.27_two-details-comic-shelf-download.zip`.
Do not merge or copy files from an earlier zic archive.

## Current implementation

- Home, Bookshelf and Comic Sources are the three primary destinations; remote browsing remains lazy.
- Details use two state owners with shared presentation components:
  - `RemoteComicDetailsScreen` owns the live source catalog and transient source failures.
  - `LocalComicDetailsScreen` owns saved comic metadata, persisted chapters/read state and offline state.
- `resolveComicDetailsRoute` routes an exact `sourceId + comicId` to local details only when durable
  comic metadata or chapters already exist; otherwise the source route remains remote.
- `SavedComicRecord` and SQLite schema version 4 persist whole-comic metadata plus a lightweight
  source chapter catalog independently of imported chapters. A comic can therefore be liked,
  collected or added to the shelf with zero downloaded chapters.
- The shared header owns whole-comic liked/shelf/collected/category actions. A chapter row opens
  Reader; its trailing action performs a durable chapter download.
- `PersistentChapterDownloadService` stores complete promoted page artifacts in a persistent offline
  root and verifies/reuses them after restart. Reader uses offline page loaders when the whole selected
  chapter is complete.
- Pull-to-refresh remains owner-specific: remote details reload the source manifest; local details
  reload the saved source catalog or rescan the local folder.
- Cross-source migration is explicit copy, never automatic title aggregation. The selected target
  source is searched by the current title and the user confirms a candidate; manual native-ID fallback
  remains available. It copies whole-comic preferences and only migrates chapters whose normalized
  title and sequence both match. Target manifests are fetched anew; progress is clamped, read state is
  copied, and source URLs/offline bytes/original records remain untouched.
- UI aggregation, management selection, category insertion, drag payloads and Widget keys use
  `sourceId + comicId` identities.
- Legacy `comic_preference`, `imported_chapter`, `reading_progress` and `chapter_read_state` keys are
  not yet fully source-composite. Migration aborts or skips native-ID conflicts instead of overwriting.
- Generated Android hosts are configured by `tool/configure_platforms.py`, including
  `android.permission.INTERNET`.
- Source/details failures remain selectable and copyable. No IP pinning, certificate bypass, login,
  challenge solving or anti-bot bypass exists.
- The reported missing `ImportedChapterRecord` catalog import is fixed.
- Reader double-tap zoom uses an app-owned tap window and cancels its timer on disposal; tests keep
  the real gesture path without a pending framework recognizer timer.

## Validation completed in this environment

```bash
python3 tool/check_repo.py
bash -n tool/*.sh
python3 -m py_compile tool/*.py
```

Additional delivery checks validate Dart delimiter balance, test registration scope, JSON/YAML/TOML
parsing, package versions, archive cleanliness and a clean re-extraction. This container does not
contain Flutter, Dart, Cargo, Android SDK or Android NDK, so no claim is made that their tests or
builds ran here.

## Required external validation

```bash
flutter pub get
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

1. Migrate comic preference, imported chapter, progress and read-state tables to fully source-composite
   keys in schema version 5, with compatibility reads and collision reporting.
2. Add a download-management surface with per-chapter cancel/retry/delete, authoritative progress and
   cover waterline projection over `PersistentChapterDownloadService`.
3. Add side-by-side migration candidate comparison (cover, authors, chapter counts and sampled titles)
   before confirmation; retain search/manual-ID selection and conservative chapter mapping.
4. Add source update ingestion and durable timestamps so Home updates reflect actual upstream changes.
5. Add source-specific typed settings for translation languages and data-saver mode.
6. Define a sandboxed Mihon/Keiyoushi adapter ABI, permissions and lifecycle before loading extensions.

# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.27.0-dev.31_cover-management-whole-download.zip`.
Do not merge or copy files from an earlier zic archive.

## Current implementation

- Home, Bookshelf and Comic Sources remain the three primary destinations; source browsing is lazy.
- Local and remote details remain separate state owners with shared presentation and exact `sourceId + comicId` routing.
- Management-mode gallery covers own single-item actions: isolated delete at the upper-right and category
  migration popup at the lower-right. Long press starts source-composite multi-selection; the batch bar only
  owns batch move/copy/clear/delete. A dedicated custom-order handle keeps reordering separate from long press.
- Details inspect and subscribe to `ChapterDownloadSnapshot`, so active and complete chapter state survives
  route exit/re-entry. Chapter task labels and cover denominators use that chapter only.
- The shared details header can download the whole comic. Known incomplete chapters are resolved and downloaded
  sequentially through the existing `ChapterDownloadService`; cancellation stops the sequence and individual
  Download Manager entries remain authoritative.
- Covers show a bottom-up waterline only for active work. A chapter task shows its chapter name and own pages;
  a whole-comic operation aggregates the catalog. Complete work shows only a compact offline badge.
- Download Manager uses chapter names as primary labels and omits progress bars for completed tasks.
- Home, History and Bookshelf reuse the same cover with the title overlaid lower-left and no source/progress rows
  below it. Reading progress is rendered in details. Exact source-composite route locks coalesce rapid taps.
- SQLite remains schema 6 with source-composite library identity and retained/acknowledgeable migration evidence.
- Reader controls use a bounded speed popup; chapter rows provide their own Material surface for visible ink.

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

1. Add a durable whole-comic queue with configurable concurrency, pause/resume and network/power policy while
   retaining per-chapter DownloadSession ownership.
2. Add side-by-side source-migration candidate comparison before confirmation.
3. Add source update ingestion and durable timestamps so Home updates reflect actual upstream changes.
4. Add source-specific typed settings for translation languages and data-saver mode.
5. Discover/manage orphaned offline artifacts without weakening ownership rules.
6. Define a sandboxed Mihon/Keiyoushi adapter ABI, permissions and lifecycle before loading extensions.

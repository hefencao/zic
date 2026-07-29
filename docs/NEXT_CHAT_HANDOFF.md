# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.30.0-dev.35_architecture-cache-reader-retention.zip`.
Do not merge or copy files from an earlier zic archive.

## Current implementation

- `0.30.0-dev.35` begins the structural App refactor required for performance work.
- `demo_home.dart` is reduced from more than 3300 lines to an orchestration-sized coordinator under an enforced
  first-stage 1800-line budget.
- `HomeLibrarySession` owns durable library/source projection, errors, loading and download subscriptions.
- `demo_home_views.dart` owns Home/Bookshelf composition and management interaction; `home_widgets.dart` owns reusable
  cover/shelf/action components.
- `CoverMemoryCache` coalesces concurrent loads and enforces entry/byte LRU limits. Cover decode width follows rendered
  size/DPR and replacement uses gapless frame retention.
- `ReaderPageBytesCache` keeps a bounded encoded-byte current/next/previous working set, shares in-flight loads and
  cancels obsolete warmups. Stable page keys and implicit adjacent retention avoid remounting media on role changes.
- Decoded frame, texture, DownloadSession and promoted artifact ownership remains unchanged.
- `ChapterCacheMaintenance` exposes persistent offline usage, trim and clear through the existing storage index and
  `CacheOps`; Download Manager is presentation/command only.
- Source migration comparison, source-composite schema 6, durable whole-comic scheduling and Android policy signals
  remain intact.

## Validation completed in this environment

```bash
python3 tool/check_repo.py
python3 tool/check_dart_structure.py
bash -n tool/*.sh
python3 -m py_compile tool/*.py
bash ./tool/check_native_header.sh
```

Additional delivery checks validate versions, JSON/YAML/TOML syntax, archive cleanliness, baseline patch
reproducibility and clean re-extraction. This container does not contain Flutter, Dart, Cargo, Gradle, Android SDK or
Android NDK, so no claim is made that their builds/tests ran.

## Required external validation

```bash
flutter pub get
flutter test apps/app/test/cover_cache_test.dart
flutter test apps/app/test/reader_page_cache_test.dart
flutter test apps/app/test/home_library_session_test.dart
flutter test apps/app/test/chapter_cache_maintenance_test.dart
flutter test packages/reader/test/reader_navigation_test.dart
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

1. Continue decomposition: extract local/remote details and source-browser orchestration from App route files without
   merging their distinct state owners.
2. Add decode/present telemetry budgets around page transitions, then use measurements to tune native decoded-frame
   and texture retention rather than adding another App-owned decoded cache.
3. Add source update ingestion and durable upstream timestamps so Home updates reflect actual source changes.
4. Add source-specific typed settings for translation languages and data-saver mode.
5. Discover/manage orphaned offline artifacts without weakening DownloadSession ownership rules.

# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.21.0-dev.24_remote-sources.zip`.
Do not merge or copy files from an earlier zic archive.

## Current implementation

- Home, Bookshelf and Comic Sources are the three primary destinations; the remote page is created only after first entry.
- Comic Sources exposes a top management action and a bottom enabled-source switcher.
- Source management persists enablement and order in SQLite schema version 3; schema version 2 is
  migrated by adding `comic_source_preference`.
- `BrowsableComicSource` owns paged/searchable discovery and metadata resource loading. App tests can
  inject fixture sources without network access.
- `MangaDexSource` is the first built-in remote source. It browses/searches titles, loads details and
  translated chapter feeds, resolves MangaDex@Home page manifests, and defaults to English
  safe/suggestive results.
- Saving/opening a remote chapter converts it to `ImportedChapterRecord`, persists the remote source
  kind and continues through the existing Reader DownloadSession/promoted-artifact path.
- Remote source page IDs are persisted independently of mutable delivery URLs. Reopening refreshes
  the manifest and reconciles progress by stable page identity.
- No Mihon extension runtime, login, cookie import, challenge solving or anti-bot bypass is included.
- Existing Home/Bookshelf management and immersive Reader controls from `0.20.0-dev.23` remain.

## Validation completed in this environment

```bash
python3 tool/check_repo.py
# repository structure: OK
# demo pages: 100
# demo Animated WebP assets: 3
```

Additional delivery checks validate Dart delimiter balance, test registration scope, JSON/YAML
parsing, shell syntax, package versions, archive cleanliness and a clean re-extraction of the final
archive. This container does not contain Flutter, Dart, Cargo, Android SDK or Android NDK, so no
claim is made that their tests or builds ran here.

## Required external validation

```bash
flutter pub get
flutter test packages/catalog/test/mangadex_source_test.dart
flutter test packages/catalog/test/imported_library_store_test.dart
flutter test packages/storage/test/imported_library_store_test.dart
flutter test apps/app/test/source_browser_test.dart
flutter test apps/app/test/library_ui_test.dart
flutter test apps/app/test/reader_controls_test.dart
flutter test apps/app/test/app_smoke_test.dart
bash ./tool/test_dart.sh
bash ./tool/test_flutter.sh
bash ./tool/analyze.sh
bash ./tool/check_native_header.sh
bash ./tool/check_webp.sh
bash ./tool/test_rust.sh
bash ./tool/build_android_native.sh release
bash ./tool/build_android.sh debug
```

## Next mainline work

1. Add source update ingestion and update timestamps so Home updates use actual remote feed changes,
   without making source pages a second catalog database.
2. Add durable per-chapter offline downloads, authoritative progress/waterline projection and
   cancel/retry actions on details and covers.
3. Add source-specific settings such as translation language and data-saver mode through typed source
   configuration, not Widget conditionals.
4. Define a sandboxed external-source ABI and permission/lifecycle model before evaluating a
   Mihon/Keiyoushi adapter.
5. Run Android device tests for source navigation, remote Reader URLs, zoom/page gesture arbitration,
   immersive UI restoration and native texture lifecycle.

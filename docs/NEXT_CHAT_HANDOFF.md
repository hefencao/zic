# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.22.0-dev.26_unified-details-refresh.zip`.
Do not merge or copy files from an earlier zic archive.

## Current implementation

- Home, Bookshelf and Comic Sources are the three primary destinations; remote browsing remains lazy.
- Comic Sources, Home updates, reading history and Bookshelf reuse `UnifiedComicDetailsScreen`.
- The common details projection merges complete upstream manifests with persisted chapters by
  `sourceId + chapterId`; source-only chapters are not auto-imported and missing upstream chapters are
  retained locally.
- Pull-to-refresh updates remote manifests or local-folder snapshots through their injected owners,
  then reloads the immutable library snapshot. Reader/DownloadSession ownership is unchanged.
- Remote chapter records persist title, authors, description, cover identity, sequence and stable page
  IDs with backward-compatible JSON decoding.
- MangaDex browse/detail/feed/@Home requests still use the catalog source boundary and existing Reader
  artifact path.
- Generated Android hosts are configured by `tool/configure_platforms.py`, including
  `android.permission.INTERNET`.
- Source and details failures remain selectable/copyable. No IP pinning, certificate bypass, login,
  challenge solving or anti-bot bypass exists.
- The reported App `Comic`/`Chapter` compile failure is repaired by importing the domain package.
- The Reader double-tap regression uses two real taps and drains the recognizer countdown timer.

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
flutter test packages/catalog/test/mangadex_source_test.dart
flutter test packages/reader/test/reader_navigation_test.dart
flutter test apps/app/test/library_ui_test.dart
flutter test apps/app/test/source_browser_test.dart
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

1. Add source update ingestion and durable timestamps so Home updates reflect actual upstream changes.
2. Add source-specific typed settings for translation languages and data-saver mode.
3. Add durable per-chapter offline downloads with cancel/retry and authoritative cover waterlines.
4. Define canonical-work matching before intentionally aggregating equivalent comics across sources.
5. Define a sandboxed Mihon/Keiyoushi adapter ABI, permissions and lifecycle before loading extensions.

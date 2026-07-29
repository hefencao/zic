# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.29.0-dev.34_source-migration-comparison.zip`.
Do not merge or copy files from an earlier zic archive.

## Current implementation

- `0.29.0-dev.34` adds a read-only, side-by-side source migration comparison before any durable target write.
- Current and target works show cover, authors, source/native identity, chapter count and reading direction.
- Catalog-owned evidence reports normalized title/author overlap, exact and sequence-only matches, unmatched
  source/target counts, bounded chapter samples and explicit risk flags.
- The migration copy action remains disabled until the target identity and risks are explicitly acknowledged.
- Comparison cover futures are cached for the dialog lifetime; acknowledgement rebuilds do not repeat cover loads.
- The existing conservative migration remains intact: only exact chapter matches can transfer progress/read state,
  target state wins, source URLs/offline artifacts are not copied and the original source is retained.
- Download Manager's chapter-list loop advances correctly, and `WholeComicDownloadQueue.close()` drains active
  chapter work before final persistence and shutdown.
- Whole-comic downloads remain a durable policy-aware scheduler over the existing chapter service and promoted
  artifacts; Android runtime signals provide metered-network and charging gates.
- Home, Bookshelf and Comic Sources remain the three primary destinations. Local and remote details retain
  separate state ownership while composing shared presentation and using exact `sourceId + comicId` routing.
- SQLite remains schema 6 with source-composite library identity and retained/acknowledgeable migration evidence.

## Validation completed in this environment

```bash
python3 tool/check_repo.py
python3 tool/check_dart_structure.py
bash -n tool/*.sh
python3 -m py_compile tool/*.py
bash ./tool/check_native_header.sh
```

Additional delivery checks validate package versions, JSON/YAML/TOML syntax, archive cleanliness, baseline patch
reproducibility and a clean re-extraction. This container does not contain Flutter, Dart, Cargo, Gradle, Android SDK
or Android NDK, so no claim is made that their builds/tests ran.

## Required external validation

```bash
flutter pub get
flutter test packages/catalog/test/library_comic_test.dart
flutter test apps/app/test/source_migration_compare_test.dart
flutter test apps/app/test/whole_comic_downloads_test.dart
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

1. Add source update ingestion and durable upstream timestamps so Home updates reflect actual source changes.
2. Add source-specific typed settings for translation languages and data-saver mode.
3. Discover/manage orphaned offline artifacts without weakening DownloadSession ownership rules.
4. Define a sandboxed Mihon/Keiyoushi adapter ABI, permissions and lifecycle before loading extensions.
5. Revisit Reader playback-control presentation as one coherent design rather than changing it in response to
   isolated Widget-test timing failures.

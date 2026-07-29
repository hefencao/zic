# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.31.0-dev.36_unified-resource-cache-pipeline-ownership.zip`.
Do not merge or copy files from an earlier zic archive.

## Architectural correction completed

- The Home/Bookshelf Presentation split remains, but cache/download algorithms no longer live in `apps/app/lib`.
- `resource_cache` owns one bounded response-memory manager for image bytes, comic details, chapter metadata and search
  results. It provides global/per-kind budgets, TTL, concurrent request coalescing, LRU, per-kind statistics,
  source-composite namespace invalidation and stale in-flight suppression after refresh/clear.
- `CachedBrowsableComicSource` is the catalog adapter. Search/detail/chapter metadata and explicit cover/source artwork
  use the shared manager. App code does not build `ResourceCacheKey` values. Raw chapter-page `loadResource`
  deliberately bypasses it; missing remote covers use the placeholder instead of caching page 1 as artwork.
- Reader direct page-byte warmup and `ReaderPageBytesCache` were removed. Reader resources again flow only through
  `ReaderBinding -> PipelineController -> DemandPlan -> LiveCoordinator -> DownloadSession/artifact`.
- Page-role Widget identity again resets stale zoom. Do not reintroduce role-independent keys or
  `allowImplicitScrolling` as a resource policy.
- `downloads` owns chapter page-artifact services, persistent artifact maintenance and the durable whole-comic queue.
- `downloads_bridge` owns only runtime network/power and JSON queue-persistence adapters.
- Download Manager receives one injected `ResourceCacheCoordinator`; response/artifact thresholds and trim/clear
  orchestration live in `ResourceCacheMaintenancePolicy`, while the screen remains a presentation/command surface.
- Partial chapters are represented by chapter metadata plus any subset of independent partial/promoted page artifacts.
  There is no all-or-nothing chapter cache object. The memory service also stores pages independently and retry skips
  the retained subset.
- A supplied `ResourceCacheCoordinator` is used unchanged. App composition must not rewrap it, replace its maintenance
  policy or inject new cache thresholds.
- ADR 0017 is superseded by ADR 0018.

## Reported failures corrected

- `download_manager.dart` no longer attempts to return `ChapterDownloadService?` as an artifact maintenance interface;
  composition passes one `ResourceCacheCoordinator` explicitly.
- Cover fallback uses `ImportedPageRecord.sourceId`, not the nonexistent `source` getter.
- The invalid page-identity retention regression was removed with the competing Reader cache.
- Navigating away and back resets the old page zoom instead of retaining a `2.25` transform.

## Validation completed in this environment

```bash
python3 tool/check_repo.py
python3 tool/check_dart_structure.py
python3 tool/test_configure_platforms.py
bash -n tool/*.sh
python3 -m py_compile tool/*.py
bash ./tool/check_native_header.sh
```

Additional delivery checks validate versions, JSON/YAML/TOML syntax, package dependency boundaries, archive cleanliness,
baseline patch reproducibility and clean re-extraction. This container does not contain Flutter, Dart, Cargo, Gradle,
Android SDK or Android NDK, so no claim is made that their builds/tests ran.

## Required external validation

```bash
flutter pub get

cd packages/resource_cache && dart test test
cd ../catalog && dart test test/cached_comic_source_test.dart
cd ../downloads && dart test test
cd ../downloads_bridge && flutter test test
cd ../reader && flutter test test/reader_navigation_test.dart
cd ../../apps/app && flutter test test/chapter_downloads_test.dart
flutter test test/home_library_session_test.dart
flutter test test/source_browser_test.dart
flutter test test/reader_controls_test.dart
flutter test test/app_smoke_test.dart

cd ../../
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

1. Add transition/decode/present telemetry that attributes blank frames, first-frame delay, decode queue time and texture
   readiness to one demand revision.
2. Build deterministic replay and benchmark cases for current-to-target transitions before changing cache windows.
3. Implement/tune encoded-memory, decoded-frame and texture retention only in pipeline/session/media owners, including
   memory-pressure shrink and safe eviction handshakes.
4. Continue state-owner decomposition of details/source-browser orchestration without merging local and remote detail
   lifecycles or moving resource policy back into Presentation.
5. Add source update ingestion and durable upstream timestamps after transition telemetry is trustworthy.

# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.31.0-dev.37_promoted-reader-artifact-cache-handoff.zip`.
Do not merge or copy files from an earlier zic archive.

## Mainline ownership now established

- `resource_cache` remains dependency-light and owns reusable source-response budgets, TTL, coalescing, LRU,
  invalidation and response/artifact maintenance coordination. It does not import `DownloadId` or own Reader pages.
- `catalog` uses `CachedBrowsableComicSource` for search, details, chapter metadata and explicit cover/artwork responses.
  Raw chapter page resources still bypass the response cache.
- Reader demand remains `ReaderBinding -> PipelineController -> DemandPlan -> LiveCoordinator -> DownloadSession`.
  Presentation does not warm adjacent bytes, own a page LRU or choose a cache window.
- `downloads` owns `ArtifactCacheStore`, `ArtifactCacheTransport` and `PromotedArtifactCacheHandoff`. The handoff observes
  authoritative sessions, submits only `promoted` final bytes, retries one failed drain pass, and completes before the
  ephemeral Reader workspace is deleted.
- A new Reader session checks one exact `DownloadId` in the durable page-artifact tier and otherwise delegates to the
  original transport. Duplicate URI identities bypass cache; range reuse requires a content-derived validator.
- Persistent handoff writes use the existing `DownloadJob -> DownloadSession -> artifact -> SQLite index` path.
  `ResourceCacheCoordinator` still reaches physical artifacts only through `ArtifactCacheMaintenance -> CacheOps`.
- Partial chapters remain chapter metadata plus any subset of independent partial/promoted page artifacts. No
  all-or-nothing chapter binary object was added.

## Reported failures addressed

- `resource_cache.dart:55` negative-TTL assertion was removed as requested.
- Failed coalesced source requests no longer create an extra unobserved Future; browse/detail error and retry state can
  handle the single authoritative failure.
- Download Manager shows `暂无下载任务或离线章节` even when cache usage/maintenance controls are visible.
- Exiting Reader drains promoted page handoffs before deleting its temporary workspace; reopening can reuse the durable
  page bytes rather than downloading them again from the source.

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
cd ../../apps/app && flutter test test/library_ui_test.dart
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

1. Add transition/decode/present telemetry that attributes blank frames, first-frame delay, decode queue time, cache
   source and texture readiness to one demand revision.
2. Build deterministic replay and benchmark cases for current-to-target transitions and warm/cold artifact paths before
   changing retention windows.
3. Implement/tune encoded-memory, decoded-frame and texture retention only in pipeline/session/media owners, including
   memory-pressure shrink and safe eviction handshakes.
4. Continue state-owner decomposition of details/source-browser orchestration without merging local and remote detail
   lifecycles or moving resource policy back into Presentation.
5. Separate explicit user-pinned offline intent from incidental reusable page artifacts if product UI later needs to
   distinguish them, without changing the shared page identity or physical artifact owner.

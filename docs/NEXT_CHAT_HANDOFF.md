# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.31.0-dev.38_durable-cover-cache-stable-reader-host-plugin-catalog.zip`.
Do not merge or copy files from an earlier zic archive.

## Mainline ownership now established

- `resource_cache` owns reusable source-response coalescing, memory budgets, TTL, LRU, revision-aware keys and exact
  invalidation. Complete `imageBytes` may use an injected `ResourceCacheByteStore`; chapter page resources remain
  outside this plane.
- `storage` supplies `FileResourceCacheByteStore` under the durable application root. Each record stores the full
  `ResourceCacheKey`, expiry, content length and content hash. Reads reject and clean expired, malformed, orphaned or
  content-mismatched records; bounds are 96 entries and 32 MiB by default. The same store exposes optional usage/trim
  maintenance so the coordinator reports and clears durable responses as a distinct cache tier.
- App composition injects that durable byte store into the one `ResourceCacheCoordinator`. Source and detail surfaces
  continue to use `CachedBrowsableComicSource`; no cover-specific Widget cache or duplicate downloader was added.
- Cache shutdown rejects new public work, lets already-owned response requests finish, drains serialized persistence,
  then closes the durable store. A cover that finishes during graceful exit is not invalidated before commit.
- Reader page and zoom hosts use stable page asset identity. Crossing the PageView midpoint only updates the page role
  and resets stale zoom in `didUpdateWidget`; it does not recreate an already-loaded media child.
- Reader bytes still follow `ReaderBinding -> PipelineController -> DemandPlan -> LiveCoordinator -> DownloadSession`.
  Presentation has no private byte LRU, keep-alive retention policy or adjacent-page preheater.
- Reader page artifacts still use `PromotedArtifactCacheHandoff` and `ArtifactCacheTransport` from `downloads`; only
  complete promoted bytes enter the persistent artifact tier.
- `catalog` now contains format-neutral metadata/index compatibility for Mihon extension repositories and Venera
  JavaScript source repositories. `ExternalComicPluginHost` and `ExternalComicPluginSession` define explicit activation
  and teardown ownership; catalog itself downloads or executes no APK/Kotlin/JavaScript code.

## Reported failures addressed

- Remote and local explicit cover/image responses can survive process restart and be restored before source loading.
  Source revision participates in the durable key when available, while namespace refresh removes old memory and disk
  records.
- The role-key remount that recreated current/neighbor Reader media around the 50% page threshold was removed. A
  regression tracks child creation/disposal before and after crossing that threshold.
- Cache lifecycle mutations cannot race a close-time drain, and malformed/orphaned durable response pairs are removed
  instead of becoming permanent misses.

## Plugin compatibility scope

Implemented now:

- strict parsing of Mihon-style extension index entries (`pkg`, `apk`, version/language/adult metadata and declared
  source identities), preserving large source IDs as decimal strings;
- strict parsing of Venera source index entries with repository-relative JavaScript entrypoints, both `filename` and
  `fileName` spellings, immediate `venera:<key>` identity when declared, and deferred discovery only for keyless entries;
- namespaced zic source/plugin identities and an explicit host/session lifecycle boundary.

Not implemented or claimed:

- installing or loading Mihon extension APKs, Kotlin class loading, Android package/signature permissions or WebView
  mediation;
- evaluating Venera JavaScript, exposing network/cookie/storage bridges, or adapting its complete source API;
- trust UI, repository signing policy, plugin updates or migration between native and external source identities.

Those belong in isolated, permissioned hosts rather than `catalog`, Reader or Presentation.

## Validation completed in this environment

```bash
python3 tool/check_repo.py
python3 tool/check_dart_structure.py
python3 tool/test_configure_platforms.py
bash -n tool/*.sh
python3 -m py_compile tool/*.py
bash ./tool/check_native_header.sh
```

Additional delivery checks validate versions, JSON/YAML/TOML syntax, package dependency boundaries, changed-file hygiene,
archive cleanliness, baseline patch reproducibility and clean re-extraction. This container does not contain Flutter,
Dart, Cargo, Gradle, Android SDK or Android NDK, so no claim is made that their builds/tests ran.

## Required external validation

```bash
flutter pub get

cd packages/resource_cache && dart test test
cd ../storage && dart test test/file_resource_cache_byte_store_test.dart
cd ../catalog && dart test test/cached_comic_source_test.dart test/external_plugin_catalog_test.dart
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

1. Add an app-level restart integration fixture that opens a real file-backed cache twice and verifies cover-card and
   detail-cover restoration through the actual composition root, not only package tests.
2. Add transition/decode/present telemetry that attributes blank frames, first-frame delay, decode queue time, artifact
   source and texture readiness to one demand revision, then build deterministic midpoint and rapid-swipe replays.
3. Implement permissioned plugin host scaffolds: Android package/signature/version gates plus
   `tachiyomix.extensionLib` ABI inspection for Mihon-compatible APKs, and a constrained JavaScript runtime/capability
   bridge for Venera-compatible sources. Keep execution out of `catalog`.
4. Define plugin repository trust, updates, source identity migration and failure quarantine before enabling installation
   UI.
5. Tune encoded-memory, decoded-frame and texture retention only from benchmark evidence in pipeline/session/media
   owners, including memory-pressure shrink and safe eviction handshakes.

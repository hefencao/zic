# zic next-chat handoff

## Sole baseline

Continue only from
`zic_v0.31.0-dev.73_pipeline-runtime-compile-closure.zip`.
It is a direct modification of the user-provided
`zic_v0.31.0-dev.62_source-management-tabs-mihon-chapter-preflight.zip`;
do not merge an earlier candidate. `mihon-main.zip` and `vibevenera-master.zip`
were read-only compatibility references and are not part of the product tree.


## Completed in dev.73

- Closed the dev.72 Dart package/API compile gaps without moving download or decode ownership back into Reader.
- `PipelineReaderSessionFactory` requires a `SourceFactory`; `pipeline_runtime` has no FFI bridge dependency. `local_media_ui` supplies the Native source at platform composition.
- Local media presentation uses `PipelinePageStream.identity` and `PipelinePageContentKind`; it no longer names artifact-cache/download identity implementation types.
- Restored frame-coalesced measured page dimensions for continuous layout.
- Preserved +7/-3 download, +2/-1 decode warmup, current/transition upload, 5/3/2 lanes, request-plan reuse and streaming progress.
- Added `tool/test_pipeline_runtime_compile_boundary.py` and updated ownership contracts.

## Completed in dev.72

- Added `pipeline_runtime` as the sole Reader resource-session composition owner. Reader submits `ReaderObs` and consumes read-only page/progress projections; it no longer constructs or disposes downloads, artifacts, transports, decode/upload lanes or sessions.
- Current-page transfer selection is derived from the observation stream inside Pipeline, removing the remaining Reader→download control path.
- Local media presentation observes `PipelinePageStream` instead of `DownloadSession`.
- Home, source browse, details and migration artwork use `ComicSourceResourceGateway` plus the shared source transport and response cache.
- Venera HTTP artwork prefers `onThumbnailLoad`; durable chapter locators continue through `onImageLoad`. Request plans are coalesced and bounded in both runtime and host transport.
- Preserved VibeVenera-derived +7/-3 downloads, +2/-1 decode warmup and 5/3/2 lanes. Do not reduce these to mask traffic issues.
- Device Tx/Rx has not been measured in the build environment. Future traffic work must add sanitized byte/request counters and use real Android traffic evidence rather than inferring network upload from pipeline `uploadDemand`.

## Completed in dev.71

- Fixed the unrelated capability-interface compile failure by using explicit capability variables and an aggregate `ConfigurableChapterResourceAccess` production path.
- Bound streaming response transport and complete-byte transform fallback atomically as `ChapterResourceAccess`; persistent downloads read one snapshot and still prefer streaming.
- Added `ComicSourceResourceGateway` as the sole App owner for source lookup, legacy Venera locator rejection, transport-pool lifecycle, Reader response loaders and chapter-download composition.
- Gateway close unbinds live download services before closing transports. Home no longer directly holds `ExternalPluginResourceTransportPool` or calls resource setters.
- Moved Home-owned source download actions into a private State extension and added atomic-binding/lifecycle regression contracts.

## Completed in dev.70

- Replaced complete-byte Venera resource RPC for ordinary images with request-plan resolution plus a composition-owned streaming `ByteResponse` transport.
- Restored VibeVenera's stable +7/-3 download window, +2/-1 decode-warm window and current/transition upload window; scheduler lanes are 5/3/2 while JavaScript request-plan invocation remains serial.
- Preserved normal receiving downloads across demand detach. Explicit cancel/dispose cancels the response subscription; HTTP error responses are aborted instead of fully downloaded before retry.
- Persistent chapter progress now follows committed chunks and publishes at a bounded cadence. Reader current-page progress hides sealed/promoted/restore-only sessions and synchronizes immediately on page changes.
- GET/HEAD cannot upload source body data. `onLoadFailed` returns a replacement request plan; full runtime bytes remain only for explicit `onResponse`/`modifyImage` transforms.
- Debug trace recursively replaces Venera resource/comic/chapter Base64 identities with hash-and-length summaries.
- Next validation must use Android device traffic and trace. Do not reduce the preload window as a substitute for fixing transport or source configuration.

## Completed in dev.68

- Made legacy Venera locator compatibility an unconditional Reader/download entry preflight; `refreshRemote: false` can no longer bypass it.
- Added App and runtime-adapter rejection before any plugin invocation for `venera-resource://` values.
- Reduced deferred Venera Reader demand to current plus one forward page, at most two download demands, and no automatic Reader network retry.
- Removed separator render objects entirely in stitched vertical mode, applied one width-fit contract across static/animated/native media, and centered the active unknown-size loading placeholder in the viewport.
- Added UI/runtime/demand/stitch regression and SDK-limited static contracts.

## Completed in dev.67

- Removed duplicate top page count, previous/next, page menu and layout switching. Bottom Slider/gestures now exclusively own page navigation; global/per-comic settings exclusively own layout.
- Removed arbitrary Reader app-bar action/title Widget injection. Callers may provide only a plain page subtitle; local-media UI no longer receives or commands `ReaderController`.
- Split Reader session settings and adaptive classification out of `reader_runtime_screen.dart`, added a 1500-line budget and static rejection of the removed APIs.
- Fixed explicit `RefreshableChapterComicSource` capability binding for legacy Venera locator refresh.
- Delayed vertical request acknowledgement until the target lazy page is laid out and its observation is published; updated the regression to wait on semantic page identity.

## Completed in dev.66

- Fixed the dev.65 Venera durable-locator scope regression by passing the active source explicitly into resource configuration restoration.
- Added a chapter-metadata schema generation and App compatibility refresh so persisted `venera-resource://token` records are replaced before Reader or download use.
- Coalesced same-locator Venera configuration resolution and in-flight Dart resource loads without retaining completed page bytes.
- Measured vertical page geometry from the already-owned static bytes or WebP container metadata; continuous layout reflows without cropping or a second ImageStream.
- Delayed layout-switch and page-navigation acknowledgement until the target scroll position has valid content dimensions, restoring top page/navigation/layout controls.

## Completed in dev.65

- Added the missing `java.util.Locale` import to the Mihon Android runtime.
- Replaced newly generated ephemeral Venera page tokens with constrained, versioned, self-describing `venera-resource:` locators. Clearing runtime token state no longer breaks later page loads; legacy `venera-resource://token` is readable only while its original runtime generation still owns the token; persisted legacy chapters are refreshed in dev.66.
- Frame-coalesced `DebugTraceLog` notifications so trace producers may record during Reader build without synchronously dirtying the diagnostics `AnimatedBuilder`.
- Added global adaptive-layout and vertical-stitch settings plus bounded per-comic direction/stitch/adaptive overrides keyed by source and comic identity.
- Replaced vertical PageView paging with proportional continuous ListView presentation. Stitching removes only the page gap.
- Mirrored the Reader slider and endpoint labels for RTL while preserving normal page indices and progress identity.

## Completed in dev.64

- Fixed the `ChapterDownloadService` capability binding by explicitly casting
  to `ConfigurableChapterResourceLoader` after the runtime type check.
- Fixed the repository-model test callback to use `owners[sourceId]` instead of
  a nonexistent `Map.operator` getter.
- Added the fourth root destination, Misc, with quick settings, Settings,
  About, download/import shortcuts, and a bounded Debug trace projection.
- Added Data, Network, Bookshelf, Reading, Download, and Appearance settings.
  Executable settings delegate to the existing catalog store, cache
  coordinator, whole-comic queue, Reader composition, and theme owner.
- App preferences persist through injected `storage_bridge` map readers and
  writers. Presentation still does not import `dart:io` or own files.
- Library backup exports catalog metadata and progress through a user-selected
  destination. Directory roots remain read-only until an indexed migration and
  rollback protocol exists.

## Completed in dev.63

- Stable page identity is independent from delivery URI. A chapter may contain
  the same source locator more than once when its `pageId` values are distinct.
- Persistent downloads resolve `mihon:` and `venera-resource:` pages through an
  injected source loader selected inside `downloads`; plugin locators no longer
  fall through to `IoTransport`.
- Reader transfer notifications are coalesced and published after build instead
  of synchronously dirtying a `ValueListenableBuilder` during Widget build.
- Venera and Mihon page messages expose recognizable WebP/GIF/etc. hints while
  byte sniffing remains authoritative. Venera receives a browser UA by default.
- Venera redirects are host-managed, cookie-aware and limited to eight hops;
  both native HTTP paths disable their own automatic redirect behavior.
- Mihon covers are source-owned opaque resources with normalized absolute URLs
  and source headers, covering relative and header-dependent thumbnails.
- Mihon page count zero is progressively resolved from details with at most two
  concurrent cached chapter preflights. Rows and the aggregate total update in
  place; individual failures are visible.
- Empty/error chapter catalogs may attempt a synthetic gallery only when a real
  non-empty page list succeeds. If the page path also fails, the catalog failure
  remains in the diagnostic chain.

## Invariants

- Misc and Settings are projections and command surfaces, not new service
  owners. They cannot open plugin transports, read cookies, retain page bytes,
  or delete cache files outside `ResourceCacheCoordinator`.
- Storage-root changes remain unavailable until catalog indexes, plugin data,
  queue state, response bytes, and page artifacts can migrate atomically with
  rollback. Displaying and copying current paths is allowed.
- Debug trace capture is bounded and observational; disabling or clearing its
  UI projection does not change Reader/pipeline/download decisions.

- Presentation does not select transports, own page bytes, create page caches or
  branch on plugin URI schemes.
- `pageId` is the stable uniqueness key; URI/source locator is mutable and may
  repeat.
- Media hints never replace byte sniffing or decoder validation.
- Page-count preflight is bounded metadata work through the cached source; it is
  not Reader demand, download policy or page-byte retention.
- Synthetic Mihon chapters cannot hide a real failure unless the same source is
  proven to expose readable gallery pages.
- Retain versioned Mihon ABI assets, read-only staging, isolated runtime process,
  payload verification and Reader/download/cache ownership.

## Validation commands

```bash
python3 tool/check_repo.py
python3 tool/check_dart_structure.py
python3 tool/check_android_runtime_dependencies.py
python3 tool/test_android_runtime_dependencies.py
python3 tool/test_mihon_chapter_contract.py
python3 tool/test_mihon_abi_routing.py
python3 tool/test_mihon_classloader_contract.py
python3 tool/test_mihon_read_only_payload.py
python3 tool/test_mihon_entry_instantiation.py
python3 tool/test_mihon_payload_context.py
python3 tool/test_venera_bootstrap.py
python3 tool/test_venera_network_policy.py
python3 tool/test_venera_response_headers.py
python3 tool/test_external_login_bridge.py
python3 tool/test_external_source_settings_contract.py
python3 tool/test_reader_streaming_contract.py
python3 tool/test_reader_layout_settings_contract.py
python3 tool/test_ui_architecture_contract.py
python3 tool/test_configure_platforms.py
bash -n tool/*.sh
python3 -m py_compile tool/*.py
bash tool/check_native_header.sh

flutter pub get
(cd packages/catalog && dart test)
(cd packages/downloads && dart test)
(cd packages/plugin_host && dart test)
(cd packages/plugin_host_bridge && flutter test)
(cd packages/reader_runtime && flutter test)
(cd apps/app && flutter test)
(cd apps/app/android && ./gradlew :plugin_host_bridge:testDebugUnitTest)
(cd apps/app/android && ./gradlew :app:checkReleaseDuplicateClasses :app:assembleRelease)
```

## Next mainline work

1. Run the full Flutter/Dart suite and Android release build to close the SDK
   validation gap for dev.65, including `misc_settings_test.dart`, `reader_controls_test.dart`, and the continuous Reader navigation regression.
2. Define an atomic directory migration/rollback protocol before adding mutable
   data, download, cache, or plugin root selectors. Add backup import only after
   validating schema and collision behavior.
3. On a real Android device, verify that a long Venera chapter continues loading after runtime process recreation and that deferred `onImageLoad` still applies to later pages.
4. Verify JMComic/18comic accepts the synthetic gallery only when body pages load,
   and preserve the complete diagnostic when both chapter and page APIs fail.
5. Verify www.wn04.ru cover rendering, repeated-image chapters, Reader opening
   and persistent chapter download with source headers.
6. Measure page-count preflight on a large Mihon catalog; retain the two-worker
   bound and source-cache reuse unless trace data proves a different owner needs
   adjustment.
## 0.24.0-dev.28 — source-composite durable library schema

- Migrate SQLite to schema version 5 so imported chapters, reading progress, comic preferences and
  chapter read state use source-composite primary keys rather than source-agnostic native IDs.
- Carry `sourceId` through `ReadingProgress`, `ComicPreference` and `ChapterReadState`, with explicit
  fallback decoding for legacy JSON and source-aware Store point queries/removals.
- Upgrade schemas 1–4 transactionally. Resolve legacy chapter-owned data from its imported chapter;
  resolve ambiguous remote preferences deterministically and persist an auditable
  `library_migration_issue` record instead of overwriting or silently dropping state.
- Remove cross-source native-ID conflict guards now made obsolete by composite storage. Two sources
  can retain the same comic and chapter IDs with independent progress, preferences and read state.
- Preflight every exact cross-source chapter match before the first durable write; merge target comic
  preferences and preserve existing target progress/read state instead of overwriting it with source state.
- Run `PRAGMA foreign_key_check` before committing a legacy schema upgrade so an invalid composite
  ownership graph rolls back rather than becoming the active library.
- Make Home/history/source cards and details chapter/read/download Widget keys source-composite so
  Flutter state cannot be reused across equal native IDs from different sources.
- Fix the reported `void` callback conditional returns and type-safe legacy `SavedComicRecord` list
  decoding without weakening product tests.
- Add schema 4→5 ambiguity-reporting, duplicate-native-ID isolation and legacy JSON fallback
  regressions; make legacy schema preparation recover development databases whose version marker was
  written before every table existed.

## 0.23.0-dev.27 — two detail owners, whole-comic shelf, durable chapter downloads

- Replace the single stateful details owner with `RemoteComicDetailsScreen` and
  `LocalComicDetailsScreen`, while reusing the same header, preference/category controls, chapter
  rows, error panel and pull-to-refresh scaffold.
- Centralize exact `sourceId + comicId` routing: an unsaved source work stays remote; durable comic
  metadata or chapters route the same source work to local details.
- Add `SavedComicRecord` and SQLite schema version 4 so a whole comic can be liked, collected or
  added to the shelf without importing an arbitrary chapter. Persist a lightweight source chapter
  catalog for the local details page.
- Make the primary chapter trailing action a durable offline download. Persist promoted page
  artifacts outside the Reader session workspace and reuse complete offline bytes after restart;
  the in-memory fallback also owns actual page bytes before reporting completion.
- Add conservative cross-source copy migration for whole-comic preferences plus exact
  title-and-sequence chapter matches. Search the selected target source by the current title, let the
  user choose a candidate (with manual native-ID fallback), fetch target manifests anew, clamp
  migrated progress, copy read state, retain the original source and never copy source URLs or
  offline bytes.
- Use source-aware comic identities for aggregation, management selection, category insertion,
  custom drag targets and Widget keys. Guard legacy native-ID collisions instead of overwriting the
  current preference/chapter/read tables.
- Fix the missing `ImportedChapterRecord` import reported by the compiler and replace fragile
  indefinite animation settling/off-screen taps with state-bound product regressions.
- Replace the framework multi-tap recognizer dependency with a Reader-owned tap window so double-tap
  zoom keeps the real gesture path without leaving a pending test timer.

## 0.22.0-dev.26 — unified source-aware comic details and pull refresh

- Replace the separate remote details presentation with one `UnifiedComicDetailsScreen` used by
  Comic Sources, Home updates, reading history and Bookshelf routes.
- Merge the complete upstream source chapter catalog with persisted library entries by
  `sourceId + chapterId`; retain saved chapters that temporarily disappear upstream and never
  import newly discovered chapters until the user opens or explicitly adds them.
- Add pull-to-refresh and an app-bar refresh command. Source manifests and local-folder snapshots
  refresh through their owning boundaries, then reconcile into the same aggregate projection.
- Persist remote comic authors and description in backward-compatible chapter JSON so a Home/history
  details route retains the same metadata and cover as the source route before its network refresh.
- Keep read/dimming, restore-unread swipe, shelf/like/favorite/category actions, source filtering,
  chapter ordering, selectable diagnostics and Reader opening behavior identical across entry routes.
- Fix the missing domain model import that caused `Comic`/`Chapter` compilation failures in the App.
- Drain the Flutter double-tap recognizer timer after the real two-tap Reader zoom regression instead
  of weakening or removing the product gesture assertion.
- Add regressions for shared source/Home details, non-persisting pull refresh, metadata persistence,
  source-aware chapter state and legacy JSON compatibility.

## 0.21.1-dev.25 — Android source networking and copyable diagnostics

- Repair generated Android hosts by idempotently adding `android.permission.INTERNET` to the main
  manifest after `flutter create`, before Android builds, and before the repository Android runner.
- Add `tool/run_android.sh` so local runs use the same host preparation path as APK builds.
- Add a bounded HTTP connection timeout, source user agent, complete socket OS-error details and one
  short retry for transient MangaDex network failures.
- Replace truncated source errors with a clean diagnostic card containing a focused summary,
  actionable guidance, scrollable `SelectableText`, long-press selection and one-tap full copying.
- Add copy actions to secondary source failures without weakening retry or source-state behavior.
- Replace the unavailable `WidgetTester.doubleTap` call with two real timed taps while preserving the
  Reader zoom assertion and product gesture path.
- Add regressions for DNS failure presentation/copying, MangaDex transient retry and generated-host
  permission idempotence.

## 0.21.0-dev.24 — remote comic source browser

- Add a third `漫画源` application destination with a top source-management action and a bottom
  enabled-source switcher.
- Add catalog-owned remote browsing contracts, searchable/paged source UI, source details and
  chapter actions.
- Add a first-party MangaDex source using its API and MangaDex@Home page manifests, restricted by
  default to English safe/suggestive results.
- Route saved/opened remote chapters through `ImportedChapterRecord`, the durable library and the
  existing Reader DownloadSession/artifact pipeline.
- Persist source enablement and order in SQLite schema version 3, including schema 2 migration.
- Persist source-provided page IDs independently of rotating remote delivery URLs so refresh keeps
  the same reading page and sub-page offset.
- Retry transient comic-detail failures in place and bound remote metadata/cover response bodies
  before buffering them in memory.
- Add fixture transport tests, source-page widget tests, source preference persistence/migration
  tests and remote URL-rotation reconciliation coverage.
- Keep Mihon-compatible plugin runtime support as a later isolated adapter rather than embedding
  Android extension code into the Flutter UI process.

## 0.20.0-dev.23 — library management and immersive Reader controls

- Remove the Home local-directory maintenance panel while retaining folder import and the
  catalog/source refresh contracts outside the primary product surface.
- Reuse the same fixed-size `ComicCoverCard` for Home update/history rails and the Bookshelf
  gallery, including centered exact-width grid layout instead of stretched covers.
- Keep custom sorting in the selected gallery/list view; add a view toggle, long-press cover
  dragging in gallery management mode, and reorderable rows in list management mode.
- Add category-scoped comic insertion plus management selection with move, category membership,
  copy-info and confirmation-gated deletion; visually isolate the destructive action.
- Remove duplicate shelf labels and selected-chip checkmarks, and collapse diagnostics behind an
  explicitly secondary Home section.
- Start Reader in immersive mode with hidden top/bottom controls; tapping reveals page slider,
  animation pause/speed, rotation, favorite and chapter-cache actions.
- Add pinch/pan and double-tap zoom, disable page swiping while zoomed, and reset stale zoom when
  navigating away from a page.
- Route GIF and WebP pause/speed through the existing player ownership path, retaining download
  identity, telemetry, native fallback and viewport-aware decode raster selection.
- Add Flutter regressions for shared cover geometry, custom gallery drag ordering, category add/
  move actions, Reader controls, rotation and zoom reset.

## 0.19.0-dev.22 — comic-level library aggregation

- Fix the catalog and SQLite library test files so all registrations remain inside
  `main()`, restoring Dart test loading without weakening product assertions.
- Move the chapter read/unread gesture key onto the owning `Dismissible` and use a
  deliberate 18% non-destructive threshold, so right-swipe reliably restores unread.
- Add persisted `comicTitle` and chapter `sequence` metadata with backward-compatible
  JSON decoding for existing imported-library records.
- Preserve aggregate identity, title and sequence when a local directory chapter is
  rescanned, while replacing only the refreshed source revision and page snapshot.
- Add `LibraryComic` as a catalog projection that groups local or remote chapters by
  comic identity, selects cover/latest/resume chapters, and exposes aggregate page data.
- Drive Home, Bookshelf, custom ordering, categories, deletion, cover cards and details
  from comic aggregates while retaining per-chapter refresh, progress and read state.
- Add catalog, SQLite and Flutter regressions for multi-chapter grouping, preference
  lifetime, chapter selection and the repaired read-state transition.

## Unreleased — Android home, bookshelf, and comic details

- Add Android-first Home and Bookshelf destinations backed by the durable local library.
- Add update and reading-history cover rails, animated cover bytes, and download waterline progress presentation.
- Add local/remote and custom-category filters, management deletion, standard sort modes, and persisted custom drag ordering.
- Add persistent liked, in-shelf, collected, category, and chapter-read state with SQLite schema v2 migration.
- Add comic details with chapter order reversal, dimmed read state, and swipe-right restore-to-unread behavior.
- Keep local folders without metadata on the direct Reader path while retaining a details route for metadata-capable sources.
- Replace stale App-level PNG fixtures with complete PNG data and stabilize keyed smoke-test discovery.

## Unreleased — persisted local-directory refresh

- Add bridge protocol 3 and `scanImageDirectory` for rescanning a persisted Android SAF
  tree without reopening the picker; desktop refresh reuses the stored directory path.
- Derive imported Reader page IDs from stable source identities instead of page indexes.
- Reconcile memory and SQLite reading progress to the same source when refresh inserts or
  removes earlier pages, and clamp only when the current source disappears.
- Add per-chapter refresh controls and added/removed page diagnostics to the local library.
- Replace the truncated PNG directory fixture with a complete one while keeping strict
  rejection tests for bare signature and incomplete IHDR data.

## Unreleased — durable imported directory library

- Reject bare or truncated PNG container labels during Dart and Android directory sniffing.
- Persist imported folder chapters and per-page detected media formats in a local catalog.
- Add SQLite storage plus Flutter application-support path composition for the catalog.
- Restore the last Reader page and paged/continuous mode when reopening an imported chapter.
- Route reopened content URI and filesystem pages through LoaderTransport, DownloadSession,
  promoted artifacts, and the same Reader runtime as freshly imported folders.
- Clamp saved progress when a refreshed chapter loses pages, ignore stale progress writes,
  and cascade-delete progress when a chapter is removed.

## Unreleased — local-media boundary and Android folder import repair

- Move local image models, recursive filesystem scanning and format sniffing from the App
  package to `packages/local_media`.
- Keep Android SAF documents as MIME/name candidates when a header probe is unavailable,
  and read them through ordinary, asset or typed-asset content resolver streams.
- Add local-media bridge protocol version 2 to detect stale native plugin caches.
- Add `tool/clean.sh` for project-wide Flutter/Dart, Gradle, Rust, CMake and JNI cache cleanup.

# Changelog

## Unreleased fixed-overlay candidate from 0.18.3-dev.21

- Generalized directory import from extension-filtered WebP files to header-detected
  local images, including extensionless and incorrectly named image files.
- Added PNG/JPEG/GIF/WebP/BMP/TIFF/ICO/AVIF/HEIF signature recognition, stronger
  container-prefix checks, recursive natural sorting, and scan/unreadable diagnostics.
- Pinned the Android file-selector implementation that returns directory paths and
  rejects unexpected `content://` results as a path-capability error instead of an
  empty-image-folder result.
- Split Reader/folder smoke coverage from decoder completion: smoke tests assert
  component identity and explicit loading state, while preview tests own ready/invalid
  behavior. Preview observers now publish the current snapshot after first layout.
- Adopted the previous WebP-safe-folder candidate plus the exact five-file
  `fixed.zip` overlay as the sole continuing baseline.
- Preserved the overlay's partial-WebP decoder fixes while replacing fixed-duration
  widget synchronization with explicit preview-state observers and controlled futures.
- Replaced the Reader app's `FakeCoordinator` with `LiveCoordinator`, real transport
  selection, `DownloadRegistry`, and promoted-artifact media loading.
- Added observer-safe `DownloadSession` snapshots, cancellable WebP byte loads, and
  explicit Reader binding detach, preventing stale promotion listeners and demand
  plans during page replacement and teardown.
- Kept Reader WebP presentation on Flutter codec until Android native texture
  lifecycle/device validation succeeds.
- Retained recursive local-folder import, natural sorting, explicit relative
  display names and single-player switching, then generalized it to header-detected images.


## 0.18.3-dev.21

- Fixed the malformed-local-WebP smoke test by giving the primary validation message a stable `webpPreviewErrorKey`.
- Changed the secondary footer status from `WebP 文件无效` to `加载失败`, so product UI no longer exposes two matching validation messages.
- Replaced the global `find.textContaining` assertion with a keyed error-widget assertion and kept the exact imported filename check.
- Added repository regression gates that reject duplicate validation status text and unkeyed malformed-WebP assertions.
- Updated workspace/native versions to the 0.18.3 baseline.

## 0.18.2-dev.20

- Replaced the platform-dependent `Future<XFile?>` picker contract with `Future<PickedWebp?>`, which carries the selected file and an explicit normalized display name.
- Fixed local-import preview titles when `XFile.fromData` reports an empty `name` in Flutter tests; route titles now receive `local.webp` and `broken.webp` from the picker result rather than re-reading platform metadata.
- Added filename fallback from `XFile.name`, URI/path basename, and finally `本地 WebP` for real system-picker results.
- Kept the stable preview route/title keys and bounded route pumping from the previous repair, while adding repository gates for display-name ownership.
- Updated the native library version and its stale Rust assertion to the 0.18.2 baseline.

## 0.18.1-dev.19

- Fixed local WebP picker widget tests by waiting for a stable preview-route marker instead of assuming one timed pump completes asynchronous picker navigation and the route transition.
- Added stable preview screen/title keys shared by production code and widget tests.
- Kept malformed-file verification separate: tests first wait for the route, then wait for the controlled validation error.
- Added repository regression gates for preview route identity and asynchronous test synchronization.
- Added a next-chat handoff document for continuing from this exact baseline.

## 0.18.0-dev.18

- Fixed the local WebP picker smoke test to use a real finite-loop fixture and added a separate malformed-file regression with a controlled in-app error.
- Added `WebpInfo` parsing for VP8X, VP8, and VP8L containers so imported bytes are validated before either codec is created.
- Added `RasterPlan` to separate the adaptive physical display target from the encoded-image decode size.
- Stopped Flutter and native paths from upscaling tiny sources during decode; small partial-frame animations now compose at intrinsic size and use nearest-neighbour rendering.
- Kept large comic pages on aligned, DPR-aware downsample targets with smooth filtering and bounded pixel budgets.
- Avoided native cursor recreation when a viewport change alters only display scale but not the actual decode raster.
- Added pure-Dart raster/parser tests and a Flutter widget regression for the partial-blend fixture.

## 0.17.0-dev.17

- Fixed the missing `DecodeTarget` import in the static demo and moved the target model into its own pipeline module.
- Added viewport/DPR-aware physical decode targets with 8-pixel alignment, aspect-preserving fit, and a four-megapixel safety budget.
- Replaced the fixed 1024-pixel Animated WebP target; native and Flutter codec paths now share the same target derived from the actual image viewport.
- Fixed Flutter codec presentation by giving the image tight expanded constraints and matching `cacheWidth`/`cacheHeight` instead of rendering at intrinsic size.
- Changed native preview playback to prepare the next frame while the current frame is visible and subtract preparation time from the encoded duration, removing decode time from the animation timeline.
- Added pause-safe pending-frame/completion scheduling, physical-target tests, and frame-pacing regression tests.

## 0.16.0-dev.16

- Bundled the three deterministic Animated WebP fixtures as real Flutter app
  assets and added a checked JSON catalog.
- Replaced the automatic static-reader launch with a demo home that exposes the
  100-page chapter, bundled Animated WebP catalog, and local WebP import.
- Added system file selection through `file_selector` 1.0.3, selected to retain
  the workspace Dart 3.6 compatibility floor.
- Added an in-app Animated WebP player that can compare the native source/cursor
  pipeline with Flutter's codec and automatically falls back when the native
  runtime is unavailable or incorrectly linked.
- Added `PixelFrame`, raw RGBA-to-Flutter image presentation, alpha
  premultiplication, finite/infinite loop playback, pause/resume, and native
  runtime provenance reporting.
- Added fixture synchronization, asset/native-byte equality gates, app entry
  tests, catalog tests, and local-import route tests.

## 0.15.0-dev.15

- Replaced the external per-ABI `ZIC_ANDROID_WEBP_ROOT` contract with a pinned
  upstream libwebp source checkout.
- Added `native/libwebp.lock` for version 1.6.0 and exact commit verification
  against the official WebM repository.
- Added host and Android CMake source builders with isolated `.deps` build and
  install trees, Android NDK ABI configuration, and a static-by-default APK link.
- Updated Android native packaging to link only source-generated libraries and
  package upstream `COPYING`, `PATENTS`, and source provenance.
- Added source-built host smoke/Rust scripts and CI coverage for all Android
  ABIs; distribution `libwebp-dev` packages are no longer used by CI.
- Made native inclusion explicit with `ZIC_ANDROID_NATIVE`; split APK builds
  include the source-built media core by default and can opt out for UI-only CI.
- Bumped the native ABI to v5 and exposed linked libwebp decoder/demux versions
  so Dart can reject an incorrectly linked runtime instead of trusting filenames.

## 0.14.0-dev.14

- Replaced the nullable `FrameCursor.decodeNext()` result with explicit
  `CursorStep.frame`, `CursorStep.needMoreData`, and `CursorStep.end` states.
- Added `CursorBinding`, so `DecodeSession` receives frame and optional loop
  capabilities with static types and no `is LoopCursor` runtime branch.
- Updated native and fake cursor factories to return typed bindings; non-loop
  EOF now enters `DecodeState.ended` instead of being confused with incomplete
  input.
- Added media/session regressions for explicit cursor states and cancellation
  disposal.
- Hardened libwebp verification by checking every byte prefix of all animation
  fixtures and adding a bytewise native cursor test.
- Added Android Rust/libwebp per-ABI packaging scripts for arm64-v8a,
  armeabi-v7a, and x86_64, with shared/static dependency layouts.

## 0.13.0-dev.13

- Added native Animated WebP frame-count, play-count, metadata-complete, cycle,
  and rewind ABI functions.
- Added explicit infinite and finite animation loop semantics. Rewind is only
  accepted after end-of-stream and finite play counts are enforced natively.
- Added `AnimationInfo` and optional `LoopCursor` media contracts.
- Updated `DecodeSession` to rewind only after held frames are consumed and to
  enter an explicit `ended` state after a finite animation is exhausted.
- Added animation-loop telemetry, a finite-loop WebP fixture, C smoke coverage,
  Rust ownership/rewind tests, and Dart session-level loop tests.

## 0.12.0-dev.12

- Replaced the native WebP cursor placeholder with real incremental Animated
  WebP decoding through libwebp partial demux.
- Decode only complete frame fragments; incomplete prefixes return
  `needMoreData` without advancing cursor state.
- Added target-size RGBA composition with WebP blend and dispose handling,
  immutable frame handles, duration propagation, and one-pass end detection.
- Added a deterministic two-frame Animated WebP fixture and Rust tests for
  complete decode, partial-prefix waiting, frame bytes, and end-of-stream.
- Added system/custom libwebp link configuration, C dependency smoke checks,
  CI installation, and repository gates.

## 0.11.0-dev.11

- Made `ReaderBinding` require explicit `Coordinator` and
  `PlaybackCoordinator` dependencies instead of deriving playback capability
  from a demand coordinator at runtime.
- Added ABI v3 native cursor create/free/decode contracts with epoch checks and
  shared source ownership.
- Added retained native frame handles with immutable metadata/data access and
  independent retain/release lifetimes.
- Added Dart `NativeCursorFactory`, `NativeCursor`, and `NativeFrame` wrappers.
- Added `SourceStatus.failed` and source-lock failure handling.
- Added reader-binding interface separation, ABI enum/version, source/cursor
  ownership, and frame-retain regression tests.

## 0.10.0-dev.10

- Replaced the stale `ReadingDirection.leftToRight` test value with `ltr`.
- Added `ReaderBinding` to drive demand reconciliation and viewport playback
  from the same reader observation, and connected the demo app to the binding.
- Added decoded-frame and renderer-output byte budgets with current-page
  reserves and low-priority non-current trimming.
- Added output byte accounting, claim-safe frame/output trimming, and frame
  budget telemetry in `LiveCoordinator`.
- Added reader-binding and frame-budget integration tests plus regression gates.

## 0.9.0-dev.9

- Removed invalid trailing commas from native source enum index expressions.
- Added split-per-ABI Android APK builds through `tool/build_android.sh`.
- Switched CI and full toolchain checks from fat APK to split APK output.
- Added viewport idle/dominant/overlap/continuous phase resolution.
- Added playback gating and coordinator integration for viewport freeze/resume.
- Added regression tests for discrete overlap, target dominance, continuous
  scrolling, and playback-gate state transitions.

## 0.8.0-dev.8

- Fixed duplicate upload work caused by source-ready and download-complete wake-ups.
- Counted renderer-owned ready output toward the decode watermark.
- Added non-cancelling lane follow-up work with per-key coalescing.
- Added explicit frame advancement; source progress alone no longer advances playback.
- Added a playback timer whose duration starts after actual present, with freeze/resume.
- Added regressions for duplicate upload, prepared depth, lane follow-up, and playback timing.

## 0.7.0-dev.7

- Imported `EncodedSource` in the frame cursor contract.
- Fixed `Artifact.readPrefix()` closing its random-access file before the
  asynchronous read completed.
- Added an immediate prefix-read/file-close regression test.
- Added renderer-owned output frame and frame uploader contracts.
- Added upload sessions and registry with upload and present claims.
- Deferred output disposal while a present claim remains active.
- Rejected and disposed stale upload results.
- Connected successful decode work to upload-demand wake-up.
- Added upload state, uploaded-frame, and presented-frame telemetry.

## 0.6.0-dev.6

- Fixed restored sniff prefixes being stored as unmodifiable lists.
- Changed artifacts to open partial writers lazily and serialize writes.
- Removed idle file handles from startup recovery and cache scanning.
- Added source-ready/source-disabled telemetry and early decode wake-up.
- Added frame/cursor contracts, frame holder claims, decode sessions, and a
  decode registry keyed by `DecodeId` and source epoch.
- Made coordinator idle detection stable across work submitted by other lanes.
- Added regression coverage for the reported session failures and decode flow.
- Copied queued byte chunks at ownership boundaries and isolated
  source-listener failures.
- Disposed frames decoded after cancellation or epoch supersession.
- Fixed coordinator upload dispatch and cancellation of detached active
  downloads during dispose.

## 0.5.0-dev.5

- Fixed the missing `DownloadSession` import in `LiveCoordinator`.
- Moved `RetryPolicy` duration validation out of const evaluation.
- Added the pure Dart media contracts, source pool, and format-aware ingress.
- Mirrored confirmed WebP downloads into native encoded sources while keeping
  artifacts authoritative.
- Rebuild encoded sources from restored partial/final artifacts.
- Added ingress and download-integration regression tests.

## 0.4.0-dev.4

- Fixed Flutter platform-generation and test working directories.
- Added explicit Flutter and Dart package test runners.
- Added cache limits, LRU planning, safe trim/clear, and released-byte reports.
- Added bounded retry/backoff for demanded failed downloads.
- Added decode, upload, and maintenance lane shells.
- Added Rust incremental byte-source ABI and Dart FFI wrapper.

## 0.3.0-dev.3

- Renamed the reserved `library` package to `catalog`.
- Added cache index, scanner, startup recovery, network lane, and live download
  coordination.

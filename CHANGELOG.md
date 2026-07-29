## 0.31.0-dev.46 — single image-stream ownership, active-run artifact priming and raw runtime channel

- Close report-30's local-image test stall by removing the second manually resolved `FileImage` stream. Static image readiness now comes only from the renderer-owned `Image.frameBuilder`; the zero-copy file-routing regression verifies `FileImage` without waiting for a host codec and explicitly unmounts the provider.
- Yield the real event queue for host codec work in animation and cold-artifact widget regressions, then explicitly unmount animated players so codecs/timers do not leak into later tests or suite shutdown. Product ready still means a frame was actually presented.
- Prime promoted page artifacts at authoritative `DownloadSession.beginRun`, before ephemeral workspace restore, while keeping pages join-only. Add coverage for observers attached after a run already became active.
- Add a raw, versioned external-plugin runtime message channel and handshake around protocol v1. Every call serializes across the boundary, validates response/request identity, rejects duplicate source identities and exposes joinable close without leaking Reader/download/artifact objects.
- Preserve the existing Home startup trace unchanged, add regressions and ADR 0030. Concrete Mihon class loading and Venera JavaScript evaluation remain isolated backend work.

## 0.31.0-dev.45 — versioned external runtime protocol and shared source adapter

- Close report-29's constant-evaluation blocker by keeping `ExternalPluginRuntimeLimits` const-capable while validating `Duration` positivity at executor/session activation instead of invoking relational operators in a const initializer.
- Add one versioned, ecosystem-neutral request/response protocol for browse, comic, chapter and binary resource operations. The wire schema accepts only bounded method-channel-safe values and never exposes Reader, demand, `DownloadSession` or artifact APIs.
- Adapt isolated Mihon and Venera runtime connections through one `ExternalPluginRuntimeSession` into ordinary namespaced `BrowsableComicSource` instances, with strict source/comic/chapter/page identity validation.
- Enforce invocation timeout, response bytes and concurrency again at the host boundary. A timeout no longer releases its permit until the underlying isolated call actually exits; queued calls cannot steal or overbook transferred permits.
- Make concurrent session close calls join one shutdown, signal the isolated connection before draining real work, reject queued work deterministically and close failed handshakes.
- Preserve the existing Home startup trace unchanged, add protocol/runtime lifecycle regressions, and record ADR 0029. Concrete Mihon class loading and Venera JavaScript evaluation remain isolated backend work.

## 0.31.0-dev.44 — visible-frame readiness, authoritative artifact priming and plugin execution contracts

- Close the report-28 compile blocker with the explicit `ResourceCacheFileByteStore` composition capability. File lookup and durable invalidation now share one statically valid owner instead of relying on promotion to the intersection of unrelated nullable interfaces.
- Make local WebP readiness mean an actually presented first frame rather than container validation. Cold-codec and target-rebuild regressions use the packaged animation fixture and retain strict visible-frame/no-black-gap assertions.
- Prime promoted-artifact reads when the authoritative replacement `DownloadSession` enters queued/receiving state. Page consumers still only join that single read; they do not create cache or network demand. Promotion waiting now checks session state before and after listener attachment.
- Extend Android Mihon pre-load inspection with normalized extension entry classes, while continuing to forbid class loading during inspection. The trust gate rejects executable activation metadata that lacks an entry class.
- Add separate immutable-payload execution request contracts for an isolated Mihon backend and a bounded Venera JavaScript backend, including invocation, response, concurrency and runtime-heap limits. Concrete engines remain downstream adapters and cannot bypass inspection, trust or session identity validation.
- Preserve the existing Home startup trace without adding new cold-start work, add queued-read and runtime-request regressions, and record ADR 0028.

## 0.31.0-dev.43 — compact cover manifest, attributable Home startup and Android Mihon metadata

- Close the external dev.42 compile blockers in product code: encoded memory sources no longer use a runtime value in a const initializer; durable file-store capabilities are explicitly narrowed; chapter bulk projection parenthesizes nullable async fallback correctly; and local animation branches require non-null encoded bytes before constructing byte-owned players.
- Replace per-cover warm metadata reads with one storage-owned `response-manifest-v1.json`. Per-entry journals remain for atomic crash recovery/migration, target file length is still verified, LRU touches are batched, and warm hits continue to return immutable file references without whole-file Dart copies.
- Add a monotonic Home startup trace covering Flutter bootstrap presentation, service-open phases, cover request, encoded source origin/length and first decoded frame. Encoded sources now distinguish memory, ordinary local files and durable cache files explicitly.
- Add the Android `plugin_host_bridge`: Mihon APK archive inspection runs off the platform thread and reads package, current signer SHA-256, version code and supported extension ABI metadata through `PackageManager` without class loading.
- Make bounded Venera inspection derive UTF-8 metadata and SHA-256 from one immutable byte snapshot, preserving repository/script key agreement and non-execution.
- Add manifest reopen/migration, encoded-origin, Home telemetry, Venera invalid-payload and Android bridge regressions, plus ADR 0027.

## 0.31.0-dev.42 — file-backed Home covers, lazy startup and concrete plugin inspection

- Correct the cold-start diagnosis: mount Flutter immediately with a startup surface, remove eager restoration of every indexed offline page, avoid a duplicate application-support path lookup, bulk-load read-state projection in one query, and project Home download badges from one SQLite index scan without materializing sessions or statting page files. Exact page commands alone restore artifacts.
- Add a file-backed encoded-image contract. Durable cover hits validate the exact key, expiry and length, then pass the immutable cache file to `FileImage` without whole-file `readAsBytes`, startup hash recalculation or per-hit metadata flush. Access recency is batched until store close, and in-process file locations are reused.
- Let ordinary local static images use the same file-provider path when no Reader/pipeline loader owns the request. Android content URIs, animations and Reader pages retain controlled byte/session fallbacks. The implementation avoids Dart-heap copies but does not claim absolute storage-to-texture zero copy inside platform decoders.
- Publish Flutter animated `ready` only after the first frame has actually been presented, retain the gapless target-rebuild invariant with a real packaged WebP fixture, and keep the cold promoted-artifact regression state-driven.
- Add concrete Mihon APK and Venera JavaScript payload inspectors over one immutable local payload: streaming SHA-256, exact-length checks, metadata-only APK parsing boundary, bounded non-executing Venera key discovery, and repository/script key agreement. Executors remain separately sandboxed adapters.
- Add file-backed cache, batched-touch, direct local-file provider, lazy artifact restore and plugin-inspection regressions, plus ADRs 0025 and 0026.

## 0.31.0-dev.41 — direct promoted reads and gapless cold decode

- Fix the reported `static_demo.dart` compile failure by importing the downloads-owned Reader page identity adapter rather than relying on a re-export side effect.
- Let a reopened Reader consume one exact immutable read of an already-promoted page artifact while the replacement `DownloadSession` continues its normal seal/promote path in the background. The page and cache transport share that read through a downloads-owned pool, removing cache-to-ephemeral-copy and re-read from first-frame latency.
- Stream background cache handoff in 64 KiB chunks and use the exact DownloadId/length as the resume validator, avoiding a second whole-page hash and giant single-chunk copy on the UI isolate. Cache read failures now fall back through the normal session/origin path with trace evidence.
- Keep the currently presented Flutter animated frame during target-only codec rebuilds and replace it only after the new frame is presented, eliminating the black gap caused by eager frame disposal. Encoded-byte changes still invalidate the frame.
- Extend transition replay with durable artifact read duration and consumer attribution, preferring the Reader-direct event when both direct consumption and session-copy events exist.
- Preserve the strict midpoint invariant before gesture release while allowing the old page to be evicted after settling; the regression still forbids a loaded page remount. Add cold-open, coalesced-read, chunking, fail-open cache, Flutter codec phase and gapless-target regressions, plus ADR 0024.

## 0.31.0-dev.40 — managed artifact capability and deterministic transition replay

- Close the reported App compilation failure without widening every chapter-download implementation: add the explicit
  `ManagedChapterDownloadService` composition capability, implemented by the memory and persistent services, and use it
  at the durable App root where artifact maintenance is required. The narrower `ChapterDownloadService` remains valid
  for UI/test adapters that do not own promoted artifacts.
- Replace the Reader midpoint regression's fixed-pixel assumption with state-driven gesture progression. The test first
  proves the target host entered the render tree while the original page is still current, then crosses the actual
  midpoint and verifies neither loaded host was disposed or recreated. Product keys and ownership are not weakened.
- Add deterministic `ReaderTransitionTraceAnalyzer` replay over the existing transition/artifact/decode/upload/present/
  first-frame/host-lifecycle trace chain. It reports cache versus origin selection, host-remount evidence, phase durations,
  missing evidence and the dominant measured phase without changing demand, retention, cache or eviction policy. The
  replay distinguishes transition revision from the revision that produced the presented frame and emits a JSON-ready
  report, so a preloaded neighbor is measured as zero transition wait instead of being attributed to later swipe work.
- Move Reader page DownloadId/trace identity construction into `downloads`, add rapid-swipe, incomplete-trace,
  host-remount and managed-capability regressions, plus ADR 0023 and updated handoff
  rules for evidence-driven retention work.

## 0.31.0-dev.39 — compile closure, transition attribution and permissioned plugin hosts

- Close the reported dev.38 Dart compilation regressions: durable `Uint8List` restoration is explicitly narrowed back
  to the caller's generic type, byte-store maintenance uses its promoted capability interface, and the stable Reader
  page host constructor accepts the `key` supplied by `PageView`.
- Move the production durable response-cache composition into one reusable storage-bridge factory and add an app-level
  two-start regression that restores both source-card and comic-detail covers through the real file-backed cache without
  invoking the raw source after restart.
- Add revision-correlated Reader/pipeline telemetry for page transition coverage, page-host mount/dispose, first-frame
  delay, artifact-cache versus origin bytes, decode demand/start and upload demand/start. Demand revisions are captured
  when work is created so a later plan cannot relabel queued work.
- Add the dependency-light `plugin_host` package. It gates Mihon-compatible APKs by repository, payload, package,
  signer, version and extension ABI metadata, and gates Venera-compatible JavaScript by repository, payload, stable
  source key and explicitly allowed capabilities before any executor receives code.
- Add plugin failure quarantine and a runtime registry that owns activated sessions, deactivation and shutdown while
  rejecting source identities already registered by another plugin. APK/Kotlin and JavaScript execution remain separate
  executor interfaces and are not claimed by this iteration.
- Add regressions for real cache restart, artifact-origin attribution, midpoint host preservation, demand/start/frame
  revision ordering, plugin gate rejection before execution, quarantine, runtime source validation and cross-plugin
  identity collision cleanup.

## 0.31.0-dev.38 — durable cover cache, stable Reader hosts and plugin catalog seam

- Persist complete `imageBytes` responses through an injected `ResourceCacheByteStore`. The file implementation stores
  the full cache key, expiry, content length and hash under the durable app root, applies bounded LRU trimming and
  restores covers before invoking a source loader after process restart.
- Extend the standard image-response TTL to seven days while preserving exact namespace invalidation, revision-aware
  identities and explicit refresh. Graceful cache shutdown now rejects new work but drains already-owned requests and
  persistence writes instead of invalidating a cover that completes during exit.
- Keep Reader page and zoom hosts keyed by stable asset identity. Crossing the PageView midpoint updates the current
  role and resets page-local zoom without disposing/recreating the loaded media child, eliminating the observed
  neighbor-page return to black/loading caused by role-key remounts.
- Add format-neutral Mihon extension and Venera JavaScript repository catalog models, strict index parsers, namespaced
  external source identities and an explicit plugin-session lifecycle boundary. Venera parsing accepts both the
  documented `filename` spelling and the current repository's `fileName` plus declared `key`; APK/Kotlin and JavaScript
  execution remain separate future sandbox hosts rather than entering catalog, Reader or download ownership.
- Include durable response bytes in unified cache inspect/trim/clear reporting and Download Manager presentation without
  bypassing page-artifact busy/ownership rules.
- Add regressions for process-reopened cover reuse, close-time persistence draining, source-revision separation,
  durable store expiry/invalidation/LRU maintenance, midpoint page-host preservation and external plugin identity parsing.

## 0.31.0-dev.37 — promoted Reader artifact cache handoff

- Persist exact Reader page bytes only after the authoritative `DownloadSession` reaches `promoted`. A package-owned
  `PromotedArtifactCacheHandoff` observes session state and drains commits before the ephemeral Reader workspace is
  removed; Presentation does not choose pages, start downloads or own a private byte cache.
- Add `ArtifactCacheStore` and `ArtifactCacheTransport` in `downloads`. A new Reader session first checks the durable
  page-artifact tier and falls back to the transport selected by `LiveCoordinator`; duplicate URI identities bypass the
  cache and range reuse requires a content-derived validator.
- Make persistent and memory chapter services expose page-granular artifact read/commit operations. Durable handoff
  writes still pass through `DownloadJob -> DownloadSession -> seal -> promote` and the existing index/`CacheOps`
  maintenance path instead of copying files or mutating the index from App code.
- Keep `resource_cache` dependency-light. It continues to own reusable source-response policy and artifact maintenance
  coordination, while `DownloadId`-specific storage remains in `downloads`.
- Remove the requested negative-TTL assertion from `ResourceCachePolicy`. Repair failed in-flight request coalescing so
  one source failure is delivered only through the caller-owned futures rather than an extra unobserved derived future.
- Restore the Download Manager empty state when cache statistics are present but no chapter/whole-comic tasks exist.
- Add regressions for failed request coalescing, exact cache hits, range validators, ambiguous URI fallback, promoted
  handoff, in-memory artifact clearing and persistent reuse after service reopen.

## 0.31.0-dev.36 — unified resource cache and restored pipeline ownership

- Correct the `0.30.0-dev.35` cache boundary. Remove the App-owned `CoverMemoryCache` and competing `ReaderPageBytesCache`; Reader presentation no longer warms current/adjacent page bytes or enables implicit page retention outside pipeline policy.
- Add the workspace-level `resource_cache` package. Cover/image responses, comic details, chapter metadata and search results share one global/per-kind budget, TTL, in-flight coalescing, LRU eviction, exact source-composite namespaces and stale-response suppression after refresh/clear.
- Add `CachedBrowsableComicSource` in catalog. Explicit source refresh invalidates the relevant search or comic namespace; chapter page `loadResource` remains a raw pass-through so encoded pages continue through demand/session/artifact ownership.
- Move chapter artifact downloads and durable whole-comic scheduling out of `apps/app/lib` into `downloads`. Move runtime network/power and JSON persistence adapters into `downloads_bridge`; the queue now explicitly closes owned environment adapters after draining work. Download Manager stays a presentation/command surface over package interfaces.
- Model partial offline chapters as independent page artifacts plus separately cached chapter metadata. `ResourceCacheCoordinator` owns shared maintenance policy and reports both planes without turning a chapter into an all-or-nothing cache entry or leaving capacity thresholds in Presentation.
- Make the memory fallback mirror production artifact semantics: each completed page is retained immediately, cancellation/failure preserves the downloaded subset, retry skips retained pages, and trim/clear evicts page records rather than whole chapters. Folder imports persist their first page as explicit cover metadata; a missing remote cover no longer silently routes a chapter page through the response cache.
- Keep cache identity construction in package adapters. App composition injects an existing coordinator unchanged, and does not construct `ResourceCacheKey` values or replace an injected maintenance policy.
- Restore Reader page-role remount semantics required to reset stale zoom and remove the invalid stable-page-identity regression. Fix the reported cache-maintenance type promotion and invalid imported-page cover field.
- Add regressions for cache namespaces, per-kind statistics, refresh supersession, clear-during-in-flight behavior, catalog cache/raw-page boundaries and platform queue persistence.

## 0.30.0-dev.35 — home decomposition and bounded media caches

- Split the 3300+ line Home shell into durable `HomeLibrarySession`, Home/Bookshelf view composition, reusable cover/shelf Widgets and a smaller navigation/use-case coordinator. Enforce a first-stage line budget on `demo_home.dart`.
- Add bounded, concurrent-load-coalescing LRU cover bytes instead of the previous unbounded process-lifetime map. Cover Widget decode targets now follow rendered size/DPR and retain the previous frame during replacement.
- Add a bounded Reader encoded-page cache with current/next/previous warmup, shared in-flight loads and obsolete-warmup cancellation. Stable page keys and implicit adjacent retention avoid remounting media solely on page-role changes.
- Expose persistent chapter-cache usage, trim and clear through Download Manager while keeping artifact/index ownership in storage and `ChapterDownloadService`. Completed/download/Reader state is not owned by the cache UI.
- Add deterministic cache, eviction, warmup, session projection, cache-maintenance and page-identity regressions. This iteration does not move native decode/frame/texture ownership into the App.

## 0.29.0-dev.34 — source migration candidate comparison

- Add an authoritative pre-write comparison for cross-source comic migration. The current and target works are shown side by side with cover, authors, source/native identity, reading direction and chapter counts.
- Add catalog-owned migration evidence: normalized title/author overlap, exact and sequence-only chapter counts, unmatched source/target chapters, chapter-pair samples and explicit risk flags.
- Require an explicit identity/risk acknowledgement before the existing conservative copy flow can continue. The comparison performs no durable writes and does not weaken target chapter identity verification.
- Cache each comparison cover load for the dialog lifetime so checking the acknowledgement box cannot repeat a remote cover request.
- Add catalog and Widget regressions for risk evidence, chapter samples, source/target identities and the disabled-before-acknowledgement confirmation action.

## 0.28.1-dev.33 — download manager OOM and queue shutdown repair

- Restore the missing `index++` in Download Manager's chapter-task list expansion. The old loop never advanced once at least one chapter snapshot existed, causing unbounded Widget construction and eventual process/WSL OOM.
- Close `WholeComicDownloadQueue` by first cancelling and draining active chapter work, then publishing the resumable final queue state, cancelling environment signals and closing the queue store/stream.
- Replace the affected chapter-download, library and source-browser tests with bounded frame waits and explicit route/widget teardown supplied in `apps.zip`; no product interaction is changed to satisfy those tests.
- Add a Dart structure gate that rejects conditional C-style `for` loops with an empty update clause, catching this OOM class before Flutter execution.

## 0.28.0-dev.32 test-harness correction — no product behavior change

- Advance simulated frame time while waiting for popup routes, route transitions, enabled buttons and refresh results instead of looping with zero-duration pumps.
- Wait for the Reader speed option to become hit-testable without changing the Reader speed UI again.
- Make paused whole-comic queue persistence assertions tolerant of an already-returning page while still proving that a restored paused job starts no new chapter.
- Release blocked test page loaders during teardown so a failed assertion cannot leave download services and Flutter test channels waiting indefinitely.
- Product code and package versions remain unchanged from `0.28.0-dev.32`.

## 0.28.0-dev.32 — durable whole-comic queue and runtime policy signals

- Replace the route-owned sequential whole-comic loop with `WholeComicDownloadQueue`, a durable JSON-backed
  scheduler keyed by exact `sourceId + comicId`. Restored jobs keep their chapter catalog and completed set;
  a process interruption converts an in-flight job back to queued work without taking ownership away from
  the existing per-chapter download service.
- Add global chapter concurrency limits, pause/resume, cancel/retry and queue-record removal. Duplicate enqueue
  requests coalesce while a job is active, and terminal chapter artifacts are re-inspected before scheduling.
- Add network and power gates. The queue can require an unmetered connection or charging, suspends active
  chapters when a condition becomes false, and resumes through the same `ChapterDownloadService` when the
  condition becomes valid again.
- Add the `runtime_bridge` Flutter/Android plugin. It reports validated network availability, Android metered
  state and battery charging state through versioned method/event channels; unsupported hosts retain the
  explicit injectable fallback instead of becoming another download owner.
- Extend Download Manager with a durable whole-comic queue section, queue policy configuration and per-job
  pause/resume/cancel/retry/remove actions while retaining the existing authoritative chapter task section.
- Restore the missing exhaustive bookshelf sort label that blocked App compilation, and replace the clipped
  Reader speed popup with a centered bounded dialog whose five options remain hit-testable on small windows.
- Add deterministic queue regressions for concurrency, policy waiting, policy loss during an active chapter,
  paused-job restoration, JSON restoration and Download Manager queue controls.

## 0.27.0-dev.31 — cover management and whole-comic downloads

- Restore management actions to each cover: delete at the upper-right and category migration through a
  popup at the lower-right. Remove the duplicate single-selection action surface; long-press starts
  source-composite multi-selection and the separate batch bar only owns batch move/copy/clear/delete.
- Preserve custom gallery ordering with a dedicated drag handle so reordering does not compete with the
  long-press multi-select gesture. Keep sort and category migration as bounded popup menus rather than
  bottom sheets.
- Make details subscribe to authoritative `ChapterDownloadSnapshot` state. A chapter keeps its spinner
  after route recreation, uses its own title and page denominator, and leaves the cover waterline
  immediately on completion.
- Add whole-comic download to the shared local/remote details header. It resolves the catalog once,
  downloads incomplete chapters sequentially through the existing chapter service, stops after
  cancellation, and preserves per-chapter task ownership in Download Manager.
- Project an active chapter or whole-comic task onto the shared cover; completed tasks use only a compact
  offline badge. Download Manager promotes the chapter name and omits the progress bar for completed
  tasks.
- Remove source/progress rows below covers, overlay the comic title at the lower-left, and keep reading
  progress in details. Coalesce rapid Home/History/Bookshelf/Source cover taps by exact source-composite
  route identity.
- Repair small-screen Reader speed-menu reachability, restore-unread ListTile material ownership, remote
  retry/pull-refresh controls and stable management interactions without changing product semantics only
  for tests.

## 0.26.0-dev.30 — migration diagnostics and interaction reliability

- Upgrade SQLite to schema version 6 by adding durable acknowledgement timestamps to
  `library_migration_issue`; pending and acknowledged records remain queryable without deleting or
  rewriting ambiguous legacy state.
- Add a Bookshelf Migration Diagnostics surface with refresh, selectable details, JSON clipboard
  export, pending/all filtering and individual or bulk acknowledgement.
- Keep the separate local/remote details owners while splitting chapter open and download locks;
  coalesce concurrent manifest persistence for the same source-composite chapter.
- Replace the restore-unread `Dismissible` lifecycle with a non-destructive right-swipe action so the
  row never leaves the chapter list while read state is persisted.
- Keep Reader controls at their final overlay positions while fading, making pause/speed/rotation and
  other controls hit-testable as soon as they are shown.
- Replace fragile bookshelf sort and category-move popup menus with explicit bottom-sheet choices and
  stable interaction identities; open Download Manager synchronously before refreshing snapshots.
- Repair reported cover/shelf fixtures, download/open ownership regressions, remote pull-refresh/retry
  interaction paths and schema-6 acknowledgement migrations without weakening product assertions.

## 0.25.0-dev.29 — authoritative download management and UI regression repair

- Add `ChapterDownloadSnapshot` and a common task lifecycle (`idle`, `downloading`, `complete`,
  `failed`, `cancelled`) to the chapter download boundary, including exact source-composite identity,
  comic/chapter labels, completed/total pages, received/total bytes and copyable failure details.
- Derive persistent progress from the existing `DownloadRegistry`, `DownloadSession` and promoted
  artifacts. Keep terminal phases authoritative while late progress callbacks drain, and preserve
  partial artifacts for retry/resume.
- Add a Download Manager reachable from Home and Bookshelf with per-chapter cancel, retry and
  confirmed offline-file deletion. Deleting bytes deliberately retains saved comics, chapter
  metadata, reading progress and read state.
- Project aggregate chapter progress onto the shared Home/History/Bookshelf cover component. Show a
  dimmed bottom-up waterline only while incomplete; restore the cover and show a compact offline badge
  when all known pages are durable.
- Fix missing-cover records so a failed/absent cover becomes a stable placeholder rather than a
  synchronous Widget-build exception.
- Mark a chapter read before opening Reader, remove the duplicate details title, make source
  management visibly reachable, and give sort/category/retry controls stable interaction identities.
- Make Reader pause/continue rebuild from its playback notifier and keep the existing media pipeline.
- Add deterministic cancel/retry/delete and Download Manager regressions, plus stronger Dart structure
  checks for nested duplicate named arguments and product contracts.

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

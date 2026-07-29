## Current iteration — compile closure, attributable transitions and permissioned plugin runtime ownership

The dev.38 compile blockers reported by external Flutter/Dart validation are closed in product code. Persistent image
bytes are explicitly narrowed from the byte-store representation to the generic request type, maintenance calls use the
promoted maintenance capability, and `_ReaderPageHost` again accepts the stable key supplied by Reader composition.
No test expectation or finder was weakened to bypass these failures.

The real App cache composition is now a reusable `storage_bridge.createAppResourceCache` factory. An app-level restart
fixture opens that exact file-backed composition twice, restores both a source-card cover and a comic-detail cover, and
fails if the raw source is invoked after reopening. This complements package-level byte-store tests and prevents the
production root/path wiring from silently diverging.

Reader and session traces now attribute transition coverage, page-host lifetime, mount-to-first-frame delay, artifact
cache/origin selection, decode demand/start and upload demand/start to stable resource identity and demand revision.
Decode/upload revisions are retained with their demand while work waits in lanes or for source readiness, so a newer
pipeline plan does not relabel old queued work. This is observation only; no Presentation cache, keep-alive window or
parallel loading policy was introduced.

A new pure-Dart `plugin_host` package implements the common pre-execution boundary for Mihon and Venera compatibility.
Inspection is separate from execution. Policy can require HTTPS repository origin, payload digest, Mihon package,
signer, version floor and extension ABI, or restrict Venera capabilities and stable source-key discovery. Activation
failure quarantine prevents automatic retry loops. `ExternalPluginRuntimeRegistry` owns activated sessions, unload and
shutdown, and closes a new session before rejecting a source identity collision. Concrete APK/Kotlin and JavaScript
executors remain unimplemented and unclaimed.

## Current iteration — durable cover cache, stable Reader hosts and plugin catalog seam

Cover/image response caching now survives application restart. `ResourceCacheManager` accepts a dependency-light
`ResourceCacheByteStore`; App composition supplies `FileResourceCacheByteStore` under the durable storage root. Only
complete `imageBytes` values are persisted, with the full identity/namespace/revision key, expiry, content length and
content hash. The standard image TTL is seven days, source-composite invalidation also removes records not currently in
memory, and a changed source revision separates new cover content from an older URI/path identity.

The unified cache maintenance projection now reports process-memory responses, durable response bytes and page
artifacts as distinct tiers. Trim and clear wait for pending durable mutations, use the store's bounded LRU maintenance,
and continue to delegate page-artifact eviction through the existing busy-safe maintenance adapter.

Cache shutdown no longer increments the epoch before active loads finish. It rejects new public requests, drains the
already-owned futures and the serialized persistence queue, then closes the store. A cover that finishes while the app
is closing can therefore reach durable storage instead of being discarded by shutdown ordering.

Reader page presentation no longer keys `_ZoomableReaderPage` by current/non-current role. The zoom and media hosts use
the stable page asset key; crossing the PageView midpoint updates `active` and resets page-local zoom in place without
recreating the media child. This removes the observed second loading/black frame caused by role-key remounts without
adding Presentation keep-alive or prefetch policy.

`catalog` also defines a format-neutral external plugin catalog seam. Mihon extension indexes preserve package/source
identities. Venera indexes accept both `filename` and the current repository's `fileName`, preserve a declared `key` as
`venera:<key>`, and defer runtime source discovery only for keyless entries. Executable APK/Kotlin and JavaScript
integration must remain separate `ExternalComicPluginHost` implementations and return explicitly closable sessions of
ordinary `BrowsableComicSource` adapters. This iteration parses and validates repository metadata; it does not claim
executable plugin support.

## Current iteration — promoted Reader artifact cache handoff

Reader sessions still use an isolated `EphemeralCacheWorkspace`, but promoted pages no longer disappear with it. The
`downloads` package now owns `ArtifactCacheStore`, a read-through `ArtifactCacheTransport`, and
`PromotedArtifactCacheHandoff`. The handoff observes authoritative `DownloadSession` snapshots, commits only final
promoted bytes, and drains before Reader workspace deletion. It does not create demand, choose a prefetch window or
retain decoded/presented resources.

`PersistentChapterDownloadService` stores the committed page through its existing registry, `DownloadJob`, artifact,
SQLite index and `CacheOps` path; the memory fallback provides the same exact-page contract. A later Reader session can
serve those bytes through the cache transport and then reconstruct its own session artifact without repeating source
network transport. Ambiguous URI mappings are not cached, and range reuse uses a content-derived validator.

`resource_cache` remains dependency-light and does not import `DownloadId`. Failed source-response coalescing no longer
creates an unobserved derived Future, so retryable browse/detail failures remain owned by the screen's existing error
state. Download Manager also renders its empty task state alongside cache usage instead of showing only maintenance
statistics.

## Current iteration — unified resource cache and restored pipeline ownership

The first Home decomposition remains: `DemoHome` coordinates routes and cross-feature use cases, while
`demo_home_views.dart`, `home_widgets.dart` and `HomeLibrarySession` separate presentation composition and durable
projection. The resource-policy part of `0.30.0-dev.35` is superseded. App-owned cover/page caches and direct Reader
adjacent-page warmup have been removed.

`resource_cache` is now a workspace package shared through composition. One `ResourceCacheManager` owns cover/image
responses, comic details, chapter metadata and search results with a global budget, per-kind budgets, TTL, in-flight
request coalescing, LRU eviction and exact source-composite namespaces. Invalidation also supersedes older in-flight
responses, so refresh or clear cannot be repopulated by a late stale request. Download Manager reports each response
kind together with the persistent artifact tier.

`CachedBrowsableComicSource` is the catalog adapter. Browse/detail/chapter metadata and source artwork use the shared
manager. Raw chapter-page `loadResource` calls deliberately bypass it and continue through
`ReaderBinding -> PipelineController -> DemandPlan -> LiveCoordinator -> DownloadSession/artifact`. The competing
`ReaderPageBytesCache`, current/adjacent warmup and implicit retention were removed; page-role changes again reset
per-page zoom rather than preserving stale transforms.

`ChapterDownloadService`, persistent page-artifact maintenance and `WholeComicDownloadQueue` now live in the pure
`downloads` application-service package. `downloads_bridge` owns only runtime network/power and JSON persistence
adapters. A partially downloaded chapter is represented by its independent page artifact records while chapter
metadata remains a separate cached response; no chapter-sized all-or-nothing cache object is introduced. The in-memory
fallback now retains and evicts individual pages too, so cancellation and retry exercise the same partial-chapter
contract as production. Cache identities for local/remote cover resources are created by catalog adapters, not App UI.

## Current iteration — source migration candidate comparison

Cross-source migration now stops at a read-only evidence boundary before any target comic, preference, chapter,
progress or read-state write. `ComicSourceMigrationComparison` is derived from the existing conservative plan and
reports both source-composite identities, normalized title and author evidence, reading-direction differences,
exact versus sequence-only matches, unmatched source/target counts and bounded chapter-pair samples.

The App presents current and target works side by side with cover, authors, source name, native ID, chapter count
and reading direction. Explicit risk rows explain title/author/direction differences, sequence-only candidates and
unmatched saved chapters. The final copy action remains disabled until the user acknowledges the target identity
and risks. Comparison cover futures are cached for the dialog lifetime; rebuilding the acknowledgement state does
not re-fetch remote covers. The existing pre-write target manifest validation and exact-only reading-state transfer
remain unchanged.

## Current iteration — download manager OOM and queue shutdown repair

Download Manager's per-chapter task expansion now advances its explicit index. A non-empty task list can no longer enter an infinite synchronous Widget-construction loop and exhaust the host process or WSL memory. The Dart structure gate also rejects conditional C-style `for` loops whose update clause is empty, so this failure class is detected without launching Flutter.

`WholeComicDownloadQueue.close()` now marks running jobs resumable, cancels and drains active chapter work, publishes the resulting durable state, then detaches runtime-environment signals and closes the store and change stream. The supplied chapter-download, library and source-browser test files use bounded frame advancement and explicit Widget-tree teardown; product interaction semantics are unchanged.

## Previous iteration — durable whole-comic queue and runtime policy signals

The whole-comic operation is now a durable scheduler rather than a route-local loop. `WholeComicDownloadQueue`
persists exact source-composite comic ownership, the chapter catalog, completed chapter identities, policy,
phase and failure state to JSON. A restored `running` job becomes `queued`; every chapter is re-inspected against
the authoritative `ChapterDownloadService` before work starts, so promoted artifacts remain the source of truth.

The scheduler enforces a global chapter concurrency limit and exposes pause, resume, cancel, retry and record
removal. An active duplicate enqueue is coalesced instead of replacing the live job. Network/power policy can
require unmetered connectivity or charging. If a condition becomes false during an active chapter, the queue
moves the job to `waitingForPolicy`, cancels that chapter through the existing service, and resumes later through
the same partial-artifact/session boundary.

`runtime_bridge` is a narrow Android signal plugin, not a downloader. Its versioned method/event channels expose
validated network availability, Android metered state and charging state. Download Manager renders durable queue
jobs and edits policy while continuing to show per-chapter tasks separately. Unsupported hosts use the explicit
injectable environment fallback.

The missing `_librarySortLabel` implementation that blocked the App test kernel is restored as an exhaustive
mapping. Reader playback speed now uses a centered bounded dialog, keeping all five choices reachable on small
viewports. Queue concurrency, policy waiting/loss, persistence and manager controls have dedicated regressions.

## Previous iteration — cover-owned management and authoritative whole-comic downloads

Bookshelf management again keeps single-comic actions on the cover: delete is isolated at the upper-right
and category migration remains a lower-right popup. A long press is the only entry into source-composite
multi-selection; the batch surface owns only batch move, copy, clear and confirmed delete. Custom-order
dragging uses a dedicated handle so it does not steal the multi-select gesture.

Local and remote details subscribe to the authoritative chapter-download stream and inspect durable state
on entry. Chapter rows therefore retain active/complete state across route recreation. A single chapter
uses its own title and page denominator on the cover, while an explicit whole-comic operation aggregates
all known chapters and downloads incomplete entries sequentially through `ChapterDownloadService`.
Cancellation stops the sequence; completion returns the cover to normal brightness and leaves only a compact
offline marker. Download Manager omits progress bars for complete tasks and uses the chapter name as the
primary label.

Home, History and Bookshelf keep the same cover geometry with no metadata rows below it. The comic title is
overlaid at the lower-left; reading progress is shown only in details. Exact source-composite route locks
coalesce rapid taps from local and source cards. Reader speed choices use a bounded overlaid popup and chapter
rows own a Material surface, repairing the reported small-screen and ink assertions without bypassing the
underlying interactions.

## Current iteration — migration diagnostics and interaction reliability

SQLite schema version 6 retains the source-composite library tables and adds `acknowledged_us` to
`library_migration_issue`. The Store can list only pending diagnostics or all retained diagnostics and
can acknowledge issue IDs transactionally. Acknowledgement is presentation state: it never deletes,
reassigns or rewrites the ambiguous legacy record.

`LibraryDiagnosticsScreen` exposes the migration evidence through selectable detail JSON, full JSON
clipboard export, refresh, pending/all filtering and individual or bulk acknowledgement. It is reachable
from the existing diagnostics area without adding another persistent catalog or migration owner.

Reader controls remain at their final overlay positions while opacity changes, so the control is
hit-testable as soon as the visible state changes. Local and remote details keep separate state owners,
but chapter opening and downloading now have independent work locks and share one in-flight manifest
ensure operation. The read-state row uses a non-destructive right-swipe action instead of a dismiss
lifecycle. Bookshelf sort and move actions use explicit bottom sheets with stable identities.

## Previous iteration — source-composite durable library identity

SQLite schema version 5 now keys imported chapters, reading progress, comic preferences and chapter
read state by `sourceId + nativeId`. `ReadingProgress`, `ComicPreference` and `ChapterReadState` carry
and serialize the source identity; Store point queries/removals and App maps use the same composite
identity. Different sources can therefore retain identical native comic/chapter IDs with independent
progress, preference, read state and deletion lifecycles.

Schemas 1–4 migrate transactionally. Legacy chapter-owned progress/read state inherits its imported
chapter source. A remote preference with multiple possible owners is assigned by deterministic
saved/import recency and every ambiguity/orphan is persisted to `library_migration_issue` rather than
silently overwritten or discarded. A foreign-key check must pass before the migrated schema version
is committed. Legacy JSON remains readable through explicit owning-source fallbacks; all new writes
include the source.

Cross-source copy no longer rejects an otherwise valid target only because another source uses the
same native ID. Every exact target chapter is freshly resolved and identity-validated before the first
durable write; target preferences are merged and existing target progress/read state is preserved.
Home/history/source cards and details chapter/read/download Widget keys are also source-composite,
preventing Flutter element state from leaking between sources.

The reported `void` callback branch returns and `SavedComicRecord.fromJson` list promotion failures are
fixed. Schema isolation, schema 4→5 ambiguity reporting and legacy JSON compatibility have dedicated
regressions.

## Previous iteration — two detail owners, whole-comic persistence and chapter downloads

`RemoteComicDetailsScreen` and `LocalComicDetailsScreen` now own different lifecycles while composing
the same header, preference/category controls, chapter rows, error presentation and pull-to-refresh
scaffold. `resolveComicDetailsRoute` is the centralized decision: exact durable `sourceId + comicId`
metadata or chapters use local details; an unsaved source result uses remote details.

`SavedComicRecord` separates whole-comic persistence from chapter persistence. SQLite schema version 4
stores source-aware comic metadata and a lightweight chapter-catalog snapshot. Liking, collecting or
adding a comic to the shelf can therefore retain the whole work with zero imported chapters. Chapter
click opens Reader; the chapter trailing action downloads that chapter.

`PersistentChapterDownloadService` uses the existing DownloadRegistry/DownloadJob pipeline but places
complete promoted page artifacts under a persistent offline root. It verifies complete chapters and
reopens page bytes after service restart. Reader selects those loaders only when the whole chapter is
complete; temporary Reader workspaces remain separately owned.

Cross-source migration is explicit and copy-based. It searches the selected target source by the
current title, lets the user confirm a candidate (or provide a manual native ID), copies whole-comic
preferences, fetches target chapter manifests, and migrates progress/read state only for
normalized-title plus sequence matches.
It never copies source URLs or offline bytes and never deletes the original source. At that release,
legacy preference/chapter/read tables were still keyed by native IDs, so collision guards stopped or
skipped unsafe writes; schema version 5 supersedes those guards with durable composite identity.

The reported missing `ImportedChapterRecord` type import is fixed in `library_comic.dart`. Reader zoom
uses an app-owned two-tap window whose timer is canceled on disposal, and App tests wait for explicit
state/hit-test conditions instead of indefinite settling around continuously animated media.

## Previous iteration — unified source-aware details and pull refresh

Comic Sources, Home updates, reading history and Bookshelf now route through one
`UnifiedComicDetailsScreen`. The screen renders the same cover, metadata, preferences, categories,
source filters, order control, read dimming, restore-unread gesture and chapter actions regardless of
entry point. The former remote-only details widget is now only a thin adapter into this common state
model.

The projection deliberately separates two layers. A source manifest is the complete current upstream
chapter catalog; `ImportedLibraryEntry` is the subset the user has opened or explicitly saved. They
merge by `sourceId + chapterId`, so refresh can reveal new chapters without silently adding them to the
library, while persisted chapters missing from a successful upstream response remain visible as local
retained entries. Source filters keep identities separate when an aggregate exposes more than one
source. Read and in-flight state also use the composite source/chapter identity inside the details UI.

Pull-to-refresh and the app-bar refresh command call each owner rather than bypassing it: remote
catalogs refresh through `BrowsableComicSource.loadComic`, local folders through the injected folder
refresher, and persisted state through `ImportedLibraryStore`. Reader/DownloadSession ownership is
unchanged. Remote author/description/cover metadata is persisted on chapter records with legacy JSON
fallbacks so Home/history can render the same details before the next network response.

The App now imports the domain models used by its source-to-library adapter, repairing the reported
`Comic`/`Chapter` compile failure. The Reader double-tap test retains two real taps and the zoom
assertion, then advances beyond the recognizer countdown so no timer remains after disposal.
Repository structural checks pass here; Flutter/Dart/Cargo/Android toolchains remain external gates.

## Previous iteration — remote comic source browser

The Android shell now has a lazy-created third `漫画源` destination, so startup does not browse the network. The top app-bar action opens a reorderable
source manager; the source page keeps a compact bottom switcher for enabled sources. Search, refresh,
paging, retry, comic details and chapter add/open actions are implemented without creating a second
Reader or library model.

`catalog` now owns `BrowsableComicSource`, descriptors and browse summaries. The first built-in
implementation is `MangaDexSource`, using injected `Transport` for API/cover requests and resolving
chapter pages through MangaDex@Home. The production default requests English safe/suggestive
content. Fixture transport tests cover browse, metadata, chapters, covers and imported records; App
widget tests use injected sources to cover the third destination, switching, management and the
remote-to-library path without external network access.

The browser is network-lazy: fixture regressions assert that no source browse occurs before the
third destination is opened. Metadata and cover/resource responses are bounded before buffering,
and a transient detail error exposes an in-place retry instead of requiring route recreation.

Remote chapters are converted to `ImportedChapterRecord` and then use the existing durable library
and Reader DownloadSession/promoted-artifact ingress. `ImportedPageRecord` now persists optional
source page IDs. Progress reconciliation uses that ID across rotating delivery URLs and retains a
legacy display-name fallback. SQLite schema version 3 persists `ComicSourcePreference`; version 2
migrates by adding only the new source preference table.

Mihon/Venera executable loading is not embedded in the built-in source iteration. `0.31.0-dev.38`
adds strict repository metadata parsers and an isolated host/session ABI, but Android APK/Kotlin and
JavaScript runtimes still require separate compatibility, trust, permission and sandbox implementations.
No login, Cookie, challenge-solving or anti-bot bypass was added.

`python3 tool/check_repo.py` and static repository checks pass in this environment. Flutter, Dart,
Cargo, Android SDK and Android NDK are unavailable, so analyzer, Flutter tests, Rust tests and APK
builds remain explicit external gates.

## Previous iteration — library management and immersive Reader controls

The Home product surface no longer exposes per-directory refresh/removal maintenance. Folder
import remains a first-class action, while media diagnostics are collapsed under a secondary
expansion section. Home update/history rails and the Bookshelf gallery now instantiate the same
`ComicCoverCard` with an exact 132 × 238 card extent and 3:4 cover ratio. The gallery centers
fixed-width cards instead of stretching them to fill arbitrary grid cells.

Bookshelf sorting no longer changes presentation mode. Gallery and list are explicit user-selected
views; custom order works in either. In management mode, a card tap selects the comic and exposes
move/category/copy operations. Deletion is separated by spacing and a divider, uses the error color,
and requires confirmation. Custom gallery order uses long-press drag targets; custom list order uses
`ReorderableListView`. A selected category can add one or more existing shelf comics, and move
semantics remove the active category before adding the target category. Duplicate inner shelf titles
and selected-chip checkmarks were removed.

Reader enters `SystemUiMode.immersiveSticky` with both control surfaces hidden. A page tap toggles
top and bottom overlays. The bottom overlay owns the page slider, pause, playback speed, clockwise
rotation, favorite and chapter-cache commands. Page jumps remain `ReaderController` commands.
Pinch/pan and double-tap zoom are page-local; PageView scrolling is disabled while zoomed and the
old page is rebuilt at identity scale after navigation.

Animation control is injected into the existing `NativeWebpPlayer`/Flutter codec composition rather
than replacing it. Controlled WebP decoding retains viewport-aware target dimensions, telemetry,
download identity and the native fallback boundary. Native and Flutter timers preserve remaining
frame delay across pause and speed changes. The chapter-cache action promotes all chapter pages in
the current Reader workspace; that workspace is intentionally session-scoped, so a durable offline
projection and persistent shelf waterline remain the next storage slice.

`python3 tool/check_repo.py` passes in this environment. Flutter, Dart, Cargo, Android SDK and
Android NDK are unavailable here, so the target tests, analyzer and device/native builds remain
external validation gates rather than claimed results.

## Previous iteration — comic-level aggregation and reliable unread restore

The persisted library now exposes a catalog-owned `LibraryComic` projection that groups
all `ImportedLibraryEntry` snapshots with the same `sourceId` and `comicId`. `ImportedChapterRecord`
persists a backward-compatible `comicTitle` and chapter `sequence`, allowing local and
future remote chapters to share one cover, preference record, shelf position and details
route without moving chapter progress or refresh ownership out of the store.

Home update/history rails and Bookshelf filtering, sorting, custom ordering, category
membership and comic deletion now operate on comic aggregates. The details route renders
all grouped chapters in sequence order, opens the selected chapter, and keeps precise
progress plus explicit read state per chapter. Refresh and identity-reconciliation ownership remain
chapter-scoped in the source/store layer; the later library-management iteration removes those
maintenance controls from the Home product surface.
Refresh copies the scanned source revision and page snapshot onto the existing chapter,
preserving its aggregate `comicId`, `comicTitle`, chapter identity and sequence.

The reported restore-unread failure was a product gesture-boundary problem: the stable key
was attached below the `Dismissible`, and the default 40% threshold made the exact test and
real short swipes unreliable. The key now identifies the gesture owner, read chapters alone
accept start-to-end dismissal, and a non-destructive 18% threshold invokes the persisted
unread transition while returning `false` to retain the row.

Two test files also contained registrations outside `main()`. Those compile breaks were
repaired without changing their assertions. A nullable constructor-parameter reference found
during delivery review was corrected to validate the normalized field. Repository structure,
native-header, JSON, shell syntax, delimiter, test-registration-scope and version-consistency
checks pass in this environment. Flutter, Dart and Rust toolchains are not installed here;
the source libwebp check also cannot fetch its pinned checkout because outbound DNS is blocked.
The full commands in `NEXT_CHAT_HANDOFF.md` remain an external validation gate.

## Previous iteration — persisted directory refresh and stable page reconciliation

Persisted local chapters can now be rescanned without reopening the system picker. Android
reuses the stored SAF tree URI through `scanImageDirectory`; desktop platforms rescan the
stored filesystem directory outside the UI isolate. The bridge protocol is version 3 so a
Dart refresh request cannot silently target older native code that only supports initial
selection.

Imported page IDs are derived from stable source identities rather than list positions.
When refresh inserts or removes files before the current page, both memory and SQLite
stores reconcile `ReadingProgress` to the same source when it still exists; only a removed
current source falls back to a clamped valid page. The source/store path supports per-chapter
refresh progress and reports added/removed page counts while leaving the previous chapter
untouched when scanning fails. The later library-management iteration removes that maintenance
presentation from Home while retaining the underlying refresh contract.

The directory test fixture now uses a complete decodable PNG. A 24-byte signature/IHDR
prefix is correctly rejected by the production sniffer because it cannot satisfy the
minimum 33-byte PNG header contract.

## Previous candidate — durable imported library and progress restore

Imported image folders now become durable catalog entries rather than route-local values.
`catalog` owns the `ImportedLibraryStore` contract and in-memory reference implementation;
`storage` provides a transactional SQLite implementation, while `storage_bridge` resolves
the Flutter application-support path. The App lists stored chapters, removes entries,
reopens content-URI or filesystem pages through the same LoaderTransport/DownloadSession
artifact ingress, and restores the last page plus paged/continuous mode.

Progress writes are monotonic by `updatedAt`, chapter refresh clamps an out-of-range page,
and SQLite delete uses foreign-key cascade. Reader viewport reconstruction preserves the
current page and direction while detaching the previous demand plan before disposal.

PNG directory sniffing now rejects a bare signature or incomplete IHDR label. Both Dart and
Android require a complete signature, IHDR length/type and non-zero dimensions before
returning PNG; full codec validation remains authoritative after admission.

## Previous candidate — imported-folder Reader artifact pipeline

The working folder importer now crosses the same production Reader boundary as manifest
chapters. A selected folder is normalized into a serializable `ImportedChapterRecord` with
stable source/comic/chapter/page identities and a revision derived from the ordered page
sources and media hints. Content URIs and filesystem paths retain distinct canonical URI
semantics, including Windows drive paths.

`ImageFolderScreen` no longer owns a standalone page index or reads the selected file
directly. It builds a `ChapterManifest`, registers platform byte loaders with
`LoaderTransport`, and runs through `ReaderRuntimeScreen`, `LiveCoordinator`,
`DownloadSession`, promoted artifacts, `ReaderBinding`, and `ReaderView`. Previous/next and
menu navigation are explicit `ReaderController.requestPage` commands consumed by
`ReaderView`; page disposal cancels pending artifact waits immediately.

Temporary cache paths, artifact reads and recursive cleanup are owned by
`packages/storage/EphemeralCacheWorkspace`; the App composition layer no longer imports
`dart:io`.

Directory-provided byte lengths are propagated into page/catalog metadata. `LoaderTransport`
includes a full-byte content hash in resume validators, so replacement content with the same
URI and length cannot be appended to a stale partial artifact.


The WebP directory sniffer now rejects incomplete `RIFF`/`WEBP` labels and a missing first
chunk tag while remaining permissive about unknown printable chunk types. Full validity is
still owned by the parser/codec. The version remains `0.18.3-dev.21` pending the external
Flutter/Android gate.

## Previous candidate — local-media package boundary and deferred SAF validation

Local image models, recursive filesystem enumeration and header sniffing have moved from
`apps/app/lib` to `packages/local_media`. The App retains only a compatibility export and
UI behavior. Android document-tree access remains in `packages/local_media_bridge`.

The Android scanner now retains MIME/name image candidates when a header stream cannot be
probed, and document reads try ordinary, asset-file and typed-asset resolver streams. A
protocol-version handshake detects stale cached native plugin code and instructs a clean
build instead of reporting its old empty-directory result as current behavior.

`tool/clean.sh` removes project Flutter/Dart, Gradle, Rust, CMake/libwebp and generated JNI
build caches while preserving lock files and pinned source.

# Implementation Status

## Previous candidate — Android scoped document-tree folder import

The remaining Android folder-import failure was not a filename or WebP signature problem.
The endorsed selector returned a raw filesystem path for a selected SAF document tree,
while single-file selection read through `ContentResolver`. On scoped-storage devices the
raw path does not inherit the tree URI grant, so directory probing could not reliably read
the same bytes that the single-file WebP workflow could open.

A dedicated `local_media_bridge` plugin now owns Android `ACTION_OPEN_DOCUMENT_TREE`,
persists the read grant, recursively enumerates `DocumentsContract` children, probes each
document through `ContentResolver.openInputStream`, and returns immutable content-URI
identities with explicit relative display names and detected formats. Switching pages reads
the selected document through that same content URI instead of reconstructing a raw path.
Recognition is layered: magic bytes are authoritative for admission, provider MIME is a
compatibility fallback, and the display-name extension is used only as the final candidate
hint; the real parser/codec still validates bytes on open. Scan results expose separate
header-recognized and metadata-fallback counts for device diagnostics. Desktop and other
IO platforms retain the isolate-backed filesystem scanner.

`PickedImage` now has an explicit `sourceId` and byte-loader contract in addition to its
compatibility `XFile`. This keeps content URI identity, display name and bytes coupled
without relying on `XFile.name` or treating a content URI as a filesystem path. Signature
checks are intentionally minimal magic-byte sniffing; the full WebP parser or Flutter codec
remains authoritative after selection. Empty-folder diagnostics now use stable wording for
scanned, unrecognized and unreadable file counts.

The package version remains `0.18.3-dev.21` until Flutter and Android device validation
passes. This candidate is not a stable baseline.

## Previous candidate — native contain geometry and permissive image sniffing

The Android external texture was previously inserted directly into a tight expanded
viewport. `Texture` has no `BoxFit`, so it stretched to the viewport even though the
reported display/decode dimensions retained the expected source ratio. Native output now
uses `NativeTextureViewport`: a centered source-canvas `AspectRatio` box provides contain
geometry and the texture fills only that box. Wide and tall layout tests cover the visual
contract independently of Android texture registration.

Folder import now treats signature recognition as format sniffing rather than full
container validation. WebP files with metadata or unknown RIFF chunks before the image
chunk are accepted by the folder boundary as long as RIFF/WEBP and a readable first chunk
tag are present; the actual WebP parser/codec remains authoritative. File-length values
smaller than an already-read prefix no longer invalidate the prefix. BMP and other raster
magic checks use minimum structural fields rather than requiring an entire declared file
inside the 64-byte probe. Empty-folder diagnostics report scanned, unrecognized and
unreadable counts separately.

Generic-image readiness is now driven by a shared `MemoryImage` stream listener instead
of a render-time `frameBuilder` callback. Production uses the same provider for readiness
and display, avoiding a second decode; tests may inject an explicit decode probe to cover
ready/failure transitions without waiting on the Flutter test image pipeline.

The package version remains `0.18.3-dev.21` until the external Flutter/Android validation
gate passes. This candidate is not a stable baseline.

## Previous candidate — header-detected mixed-image folder import

Directory import no longer filters filenames for `.webp`. It recursively examines all
ordinary files outside the UI isolate, probes their file headers, and creates a
`PickedImageFolder` containing explicit relative names and detected formats. Files with
missing, misleading or uppercase extensions behave identically. A folder is considered
empty only when no recognized image signature is present; diagnostics retain scanned
and unreadable counts. Android `content://` results are rejected as an unsupported path
contract rather than being misreported as an empty folder.

The two preview-state timeouts reported in `app_smoke_test.dart` are removed from the
smoke boundary. Reader hosting and folder switching now assert keyed component identity,
source URI, format and explicit loading state while byte futures are deliberately held.
Valid/invalid decoder completion remains in dedicated preview tests. Both WebP and mixed
image players publish their current state snapshot after first layout so an observer
cannot miss the initial state.

The package version remains `0.18.3-dev.21` until the Flutter/Android validation gate
passes. This candidate is not a stable baseline.

## Previous fixed-overlay baseline — production Reader artifact ingress

### Baseline ownership

The current baseline is the prior complete WebP-safe-folder candidate with the five
files from `fixed.zip` replaced exactly as recorded in
`docs/FIXED_OVERLAY_BASELINE.md`. All work below is layered on that merged tree.
The package version remains `0.18.3-dev.21` until Flutter and Android validation
passes; archive names no longer carry the old
`_webp-safe-folder-candidate_UNVERIFIED` suffix.

### Reader production ingress

The Reader app runtime no longer composes its demand plan with `FakeCoordinator`.
`ReaderBinding` now drives a real `LiveCoordinator` and `DownloadRegistry`. Asset,
file and HTTP identities use the manifest-owned `DownloadId`; media bytes are read
only after the corresponding `DownloadSession` reaches `promoted`, so Reader
telemetry and the displayed WebP share the same source identity and artifact.

`DownloadSession` exposes an observer-safe snapshot contract for promotion/failure
waiting. Observer failures cannot mutate or abort the authoritative state machine.
The app runtime detaches every prior demand plan when the physical viewport target
changes and again on disposal, then cancels coordinator work before disposing the
registry and its temporary artifact root. `NativeWebpPlayer` also owns a
`WebpLoadToken`; disposal cancels an in-flight promoted-artifact wait and immediately
removes its snapshot listener. This closes stale-demand, offscreen-listener and
teardown races that were hidden by the previous fake coordinator.

This is a staged production integration: network/artifact ingress is real, while the
visible Reader WebP remains on the crash-safe Flutter codec. Native decode/upload/
present remains an explicit standalone experiment until device lifecycle checks pass.

### Test synchronization

The overlay's local Flutter fixes are preserved, but asynchronous preview tests now
synchronize through explicit preview-state regions, observer snapshots and controlled
picker/catalog futures. They do not advance a guessed fixed frame duration, identify components by
copy, or depend on `XFile.fromData` metadata.

### Validation status

Repository constraints and available host syntax/native-stub checks pass in this
sandbox. Flutter, Dart, Rust/Cargo, Android SDK and Android NDK remain unavailable,
so this tree is still an unverified candidate and is not a stable versioned baseline.

## Unreleased candidate from 0.18.3-dev.21 — crash-safe WebP entry and local folder switching

### Reader smoke timeout repair

The failing helper repeatedly issued zero-elapsed pumps while waiting for a widget
inside a route transition. Elapsed transition time never advanced, so the keyed
Reader media page remained offstage even though the destination route had been
pushed. Navigation coverage now stops at the keyed destination route with
`skipOffstage: false`. Reader media content is a separate test that injects a
one-page chapter manifest directly and synchronizes on `WebpPreviewState.ready`.
Catalog and static routes likewise use stable screen/entry keys rather than copy.

### Crash-safe WebP activation

Reader media, bundled WebP, local single-file import, and local-folder import all
start on `WebpPlayerEngine.flutter`. Reader and folder switching keep engine controls
hidden so their normal workflows cannot start FFI/texture. In standalone previews,
selecting `Native（实验）` opens an explicit confirmation dialog; cancellation leaves the
Flutter engine selected without native work. Native initialization and present
failures still emit attributed fallback telemetry and return to Flutter codec.

Android `SurfaceProducer.scheduleFrame()` is posted to the main handler rather
than called from the serial blit worker. Surface callbacks use
`onSurfaceAvailable`/`onSurfaceCleanup`; the blit lane retains the current frame
for redraw and releases it on replacement, resize, output release, or detach.

### Original local WebP folder stage (superseded)

This stage first introduced recursive folder enumeration, natural sorting, explicit
relative display names and a single current player. The current candidate supersedes
the `.webp` filename filter with mixed-image file-header detection while retaining
those ownership and switching guarantees.

### Validation status

Repository constraints and available syntax/native stub checks pass in this
sandbox. Flutter, Dart, Rust/Cargo, Android SDK, and Android NDK are not installed
here, so the target Flutter tests and device/native gates must still be run in the
external toolchain environment. Version remains `0.18.3-dev.21`; this is an
unverified validation candidate, not a stable baseline.

## 0.18.3-dev.21 — unambiguous malformed-WebP error state

### Root cause

The malformed-file preview rendered two widgets containing `WebP 文件无效`: the primary validation detail and the footer status. `find.textContaining` therefore correctly returned two matches even though navigation, filename ownership, and validation were all working.

### Repair

The detailed validation message now owns `webpPreviewErrorKey`. The footer reports the broader state `加载失败`, while the test waits for and reads the keyed detail widget. Repository gates reject both a duplicated footer validation phrase and a return to page-wide text matching.

### Validation before the next chat

```bash
cd /home/unkloser/projects/zic
flutter pub get
cd apps/app
flutter test test/app_smoke_test.dart
cd ../..
bash ./tool/test_flutter.sh
bash ./tool/test_dart.sh
bash ./tool/analyze.sh
```

Continue from `zic_v0.18.3-dev.21.zip` only after those checks pass in the Flutter-equipped environment.

## 0.18.2-dev.20 — explicit local-import display-name ownership

### Root cause

`XFile.fromData(..., name: ...)` does not provide a portable guarantee that the resulting `XFile.name` is non-empty in every Flutter test backend. The previous route synchronization repair reached the correct preview screen, but `WebpPlayerScreen.file` reconstructed its title from `file.name`, so the keyed title existed with an empty string.

### Repair

`WebpPicker` now returns `PickedWebp`, which owns both the `XFile` and its normalized `displayName`. Production system-picking derives the name from `XFile.name`, then the path basename, then `本地 WebP`. Tests inject the expected display names explicitly. `DemoHome` passes the owned name into `WebpPlayerScreen.file`, and the screen only falls back to file metadata when no explicit non-empty name is supplied.

The stable route/title keys and bounded pumping remain in place. This separates three concerns cleanly: asynchronous route synchronization, selected-file bytes, and user-facing naming.

### Validation before the next chat

Run at minimum:

```bash
cd /home/unkloser/projects/zic
flutter pub get
cd apps/app
flutter test test/app_smoke_test.dart
cd ../..
bash ./tool/test_flutter.sh
bash ./tool/test_dart.sh
bash ./tool/analyze.sh
```

Continue from `zic_v0.18.2-dev.20.zip` only after those checks pass in the Flutter-equipped environment.

## 0.18.1-dev.19 — deterministic local-import route tests

### Picker route synchronization

The local picker is asynchronous and the material route transition is scheduled after the picker future completes. A single fixed-duration `pump` can end on the first route frame rather than after the destination is discoverable, so exact-title finders were timing-dependent. The preview now exposes stable screen and title keys, and the widget tests use a bounded frame pump until the destination marker appears.

Malformed imports use the same route marker, then independently wait for the controlled `WebP 文件无效` state. This preserves the product behavior while removing dependence on animation timing and codec scheduling.

### Next chat

Continue from `zic_v0.18.1-dev.19.zip` only. The next engineering target remains Android `SurfaceProducer` texture presentation, followed by runtime telemetry and real reader-page integration.

## 0.18.0-dev.18 — validated local import and source-aware raster quality

### Local import stability

The picker route test now injects the real finite-loop WebP asset rather than a twelve-byte RIFF signature. `WebpInfo` validates complete RIFF length and reads VP8X, VP8, or VP8L canvas dimensions before the preview creates a Flutter or native codec. Malformed imports remain on the preview route and show a controlled error instead of feeding invalid bytes into the image pipeline.

### Decode raster versus display target

`DecodeTarget` remains the DPR-aware, eight-pixel-aligned physical display target. The new `RasterPlan` derives the actual encoded-image decode dimensions. Large images are downsampled to the bounded display target, while sources smaller than the viewport remain at intrinsic dimensions. This prevents animated codecs from interpolating tiny partial subframes before composition and avoids allocating multi-megapixel buffers for four-pixel fixtures.

Both native `RawImage` and Flutter `Image.memory` use nearest-neighbour rendering only for very small sources enlarged by at least 2x. Normal comic pages retain medium filtering. Native cursor identity follows the decode raster, so viewport-only display changes no longer recreate a cursor when the decoded pixel dimensions remain unchanged.

### Next iteration

1. Move native RGBA presentation to Android `SurfaceProducer` texture output.
2. Add device telemetry for decode raster, display scale, frame preparation, and present deadlines.
3. Connect the source-aware raster plan to real reader page decode sessions.
4. Add local chapter/CBZ import with persisted catalog metadata.

## 0.17.0-dev.17 — adaptive physical targets and deadline-based WebP playback

### Compile and target repair

`static_demo.dart` now imports the pipeline contract that owns `DecodeTarget`. The target itself has moved into a dedicated pure-Dart module. `DecodeTarget.viewport` converts logical viewport dimensions through the device pixel ratio, while `DecodeTarget.fit` preserves a known source aspect ratio inside that physical viewport. Both paths align dimensions to eight pixels and enforce a bounded decoded-pixel budget.

The static reader recreates its diagnostic binding when MediaQuery dimensions or DPR change. The Animated WebP preview derives its target from the exact `LayoutBuilder` image area, so app bars, controls, rotation, split-screen, and device density are reflected in decode identity.

### Flutter codec scaling

The Flutter path no longer places an intrinsic-size `Image.memory` inside a loose `Center`. It receives tight full-area constraints and matching physical `cacheWidth`/`cacheHeight`, with medium filtering. Tiny bundled fixtures now fill the preview correctly, while large imported files are decoded to the same bounded physical target as native.

### Native pacing

The previous preview decoded the next frame only after the current frame timer expired, making wall time equal to encoded duration plus decode/image-construction time. The player now decodes and builds the next `ui.Image` while the current frame is visible. `FramePacing.remaining` subtracts that preparation time from the current frame duration and presents immediately on overrun. Pause/resume preserves pending deadlines, and finite playback waits through the final frame duration before reporting completion.

### Next iteration

1. Replace diagnostic RGBA-to-`ui.Image` copies with Android texture upload.
2. Feed viewport target revisions into real reader decode sessions without recreating diagnostic controllers.
3. Add device timing telemetry comparing encoded, decode, upload, and present intervals.
4. Add local chapter/CBZ import and persistent catalog entries.

## 0.16.0-dev.16 — runnable Animated WebP app entry and local import

### Bundled animation assets

The three deterministic native decoder fixtures are now copied into the Flutter
asset bundle with a checked catalog. Repository validation compares the bundled
bytes with `native/media_core/testdata`, validates RIFF/WEBP headers and declared
byte lengths, and requires all three entries to remain reachable from the app.

### App navigation and local import

The app now opens a demo home instead of entering the 100-page static chapter
automatically. Separate entries open the static reader, a bundled Animated WebP
catalog, and the platform file selector for a local `.webp`. Local files are read
through `XFile` bytes, so the preview does not depend on a manifest or direct I/O
in the reader package. `file_selector` 1.0.3 preserves the current Dart 3.6 SDK
floor.

### Native preview path

The Animated WebP preview creates a `NativeSource`, appends and seals the selected
bytes, validates the pinned libwebp runtime, creates a typed native cursor, copies
`PixelFrame` RGBA bytes into a Flutter `ui.Image`, and follows native duration and
loop metadata. RGBA is premultiplied before presentation. The user can switch to
Flutter's codec for comparison. Missing or invalid native libraries cause an
automatic Flutter-codec fallback instead of a blank page.

### Next iteration

1. Replace the diagnostic RGBA copy with the Android `SurfaceProducer` texture
   registry and serial native blit worker.
2. Connect reader page roles to the real native player instead of the standalone
   preview route.
3. Add import of a local directory/CBZ chapter and persist the resulting catalog.
4. Add Android device tests for lifecycle-safe output retirement and overlap.

## 0.15.0-dev.15 — pinned libwebp source builds

### Source ownership

Host and Android builds no longer accept prebuilt per-ABI libwebp directories.
`native/libwebp.lock` pins libwebp 1.6.0 to the official WebM repository and
commit `4fa21912338357f89e4fd51cf2368325b59e9bd9`. `fetch_webp.sh` creates a
shallow detached checkout and verifies the exact commit before any native build.
A local source override is rejected unless it is the pinned git checkout or the
caller explicitly enables an unpinned development source.

### Reproducible host and Android builds

`build_webp_host.sh` and `build_webp_android.sh` use the upstream CMake project
with only libraries enabled. Build and install outputs are isolated below
`.deps` by source version, platform, ABI, mode, and link type. Android uses the
NDK CMake toolchain for arm64-v8a, armeabi-v7a, and x86_64. `media_core` links
those generated artifacts; no downloaded binary archive is accepted.

Android defaults to PIC static archives linked into `libmedia_core.so`, avoiding
versioned shared-library SONAME dependencies in `jniLibs`. An explicit shared
mode remains available for diagnostics. Android assets include upstream COPYING, PATENTS, and exact
source provenance.

### CI and local checks

Host C smoke and Rust tests now build the pinned source first. CI no longer
installs a distribution `libwebp-dev` package and has a dedicated Android-native
job that builds all configured ABIs. Flutter-only split APK CI uses
`ZIC_ANDROID_NATIVE=0`; normal `build_android.sh` includes native media by
default. ABI v5 also exposes the linked decoder and demux versions; the Dart
bridge reports whether both equal the pinned 1.6.0 packed version.

### Next iteration

1. Add the Kotlin `SurfaceProducer` texture registry and serial blit worker.
2. Pass retained frame handles through JNI without MethodChannel pixel copies.
3. Separate texture creation, first blit, present, and lifecycle-safe retirement.
4. Add Android device tests for background/foreground and PageView overlap.

## 0.14.0-dev.14 — statically typed cursor outcomes and Android native packaging

### Cursor contract repair

`FrameCursor.decodeNext()` no longer returns nullable frames. `CursorStep`
separates a produced frame, an incremental wait, and terminal end-of-stream.
`CursorBinding` carries the mandatory frame cursor and an optional loop view.
`DecodeSession` stores that binding directly and no longer performs a runtime
`is LoopCursor` check or uses `null` to infer native state.

A non-loop cursor can now report a real terminal end. A looping cursor receives
rewind only after an explicit end step and an empty holder. Cancellation still
disposes a frame returned after the demand was superseded.

### Incremental decoder hardening

The libwebp C smoke test now parses every byte prefix of all three deterministic
fixtures and rejects false parse errors or complete frames without fragments.
The Rust ABI test appends the primary animation one byte at a time, drains only
real complete frames, and verifies that cursor indexes never advance on
`NeedMoreData`.

### Android native packaging

`tool/build_android_native.sh` builds `media_core` for arm64-v8a,
armeabi-v7a, and x86_64 using the Android NDK and per-ABI libwebp libraries. It
packages `libmedia_core.so` and shared libwebp dependencies into Flutter
`jniLibs`, or supports PIC static archives when requested.
`tool/check_android_native.sh` validates the produced layout. The split APK
script invokes native packaging whenever `ZIC_ANDROID_WEBP_ROOT` is configured.

### Next iteration

1. Add a Kotlin `SurfaceProducer` registry and a dedicated serial blit worker.
2. Pass retained native frame handles to Android through JNI without copying
   RGBA through MethodChannel.
3. Separate texture allocation from first blit and add lifecycle-safe retirement.
4. Add Android device tests for background/foreground and PageView overlap.

## 0.13.0-dev.13 — animation metadata and loop semantics

### Native cursor metadata

ABI v4 adds frame count, WebP play count, metadata completeness, zero-based
cycle, rewind, and frame-cycle accessors. The native decoder refreshes metadata
from every successful partial demux. Rewind is accepted only after a real
end-of-stream result. A play count of zero is infinite; a positive value limits
the total number of cycles. Rewind resets canvas composition and frame numbering
while retaining source ownership and epoch.

A deterministic `finite_loop.webp` fixture declares two frames and a play count
of two. Rust tests cover one allowed rewind and the final rejected rewind. The
C smoke test validates frame count and loop metadata independently through the
installed libwebp headers and library.

### Session loop ownership

The media contract now exposes `AnimationInfo` and the optional `LoopCursor`
capability. `DecodeSession` keeps non-looping fake/fallback cursors unchanged.
For a looping cursor, it rewinds only after EOF and only when the holder is
empty, so a deeper watermark cannot introduce duplicate frame indexes while an
older cycle is still retained. Infinite content continues with a new cycle;
finite content enters the explicit `DecodeState.ended` state once its play count
is exhausted.

Decode snapshots expose animation metadata and cycle. Every successful rewind
emits `animationLoop` telemetry.

### Next iteration

1. Add Android native build/package automation for arm64-v8a, armeabi-v7a, and
   x86_64, including libwebp dependencies.
2. Add a Kotlin `SurfaceProducer` registry and serial blit worker.
3. Connect native frame handles to an Android texture uploader without sending
   RGBA bytes through MethodChannel.
4. Add lifecycle-safe texture retirement and background/foreground tests.

## 0.12.0-dev.12 — real incremental Animated WebP decode

### Native decoder

The existing ABI v3 cursor now performs real WebP work instead of returning
`unsupported`. It reparses the authoritative committed prefix with
`WebPDemuxPartial`, requests the next one-based frame, and only decodes when the
iterator marks that frame complete. A partial frame returns `needMoreData`
without mutating the canvas or advancing the frame index.

Complete frame fragments are decoded to straight RGBA with libwebp, scaled to
the physical `DecodeId` target, and composed onto a persistent target-size
canvas. Composition implements `WEBP_MUX_BLEND`, `WEBP_MUX_NO_BLEND`, and
previous-frame background disposal. The immutable composed canvas becomes the
retained native frame payload, with frame duration propagated in microseconds.

The decoder currently performs one pass. Session-level loop count and cursor
reset semantics remain explicit next work rather than being hidden in the
native cursor.

### Native dependency boundary

`build.rs` links `webpdemux` and `webp`. Desktop builds use system libraries;
custom/Android builds may set `ZIC_WEBP_LIB_DIR` and optionally
`ZIC_WEBP_STATIC=1`. The Flutter Android package does not yet bundle these
transitive native libraries.

A deterministic two-frame lossless Animated WebP fixture is checked into the
native test data. Rust tests validate partial-prefix waiting, real red/green
RGBA output, duration/size metadata, and end-of-stream. A C smoke program also
compiles and runs directly against the installed libwebp to validate the
headers, partial demux behavior, fixture metadata, and fragment decode.

### Next iteration

1. Add animation metadata and loop/repetition semantics to the cursor/session
   contract.
2. Add Android `SurfaceProducer` registry and serial blit worker.
3. Package media-core and libwebp per Android ABI and connect a no-copy uploader.
4. Replace baseline software frame scaling with decoder-native scaling where
   platform profiling proves it beneficial.

## 0.11.0-dev.11 — explicit playback capability and native frame ABI

### Requested fix

`ReaderBinding` no longer derives a local `playback` variable from a value typed
as `Coordinator`. Its constructor now requires the demand and playback
capabilities separately:

```dart
required Coordinator coordinator,
required PlaybackCoordinator playback,
```

The binding stores `_coordinator` and `_playback` with their actual interface
types. The app and tests explicitly pass the same live/fake object when it
implements both contracts. A regression test also supplies two separate
objects, proving the binding does not depend on a runtime type check.

### Native cursor and frame ownership ABI

The Rust media core ABI is now version 3. `ByteSource` uses shared source state;
a cursor clones that state, so releasing the source handle cannot leave an
existing cursor with a dangling pointer. Source reset still advances the epoch,
and cursor decode rejects stale epochs.

Added stable C/Rust/Dart symbols for:

- cursor create/free/epoch/decode-next;
- frame retain/release;
- frame epoch/index/size/duration/format/length/data access.

A frame handle owns an `Arc` to immutable frame data. `retain` creates another
independent handle, and the data remains valid until the final handle is
released. Dart wraps this as `NativeCursor`, `NativeFrame`, and
`NativeCursorFactory`; copied byte access does not expose a long-lived raw
pointer to application code.

The ABI intentionally returns `unsupported` for sealed WebP decode until the
real WebP decoder is linked. It does not synthesize frames or advance cursor
state. Unknown/incomplete input returns `needMoreData`.

### Source failure status

Added `SourceStatus.failed` at ABI index 6 and mapped lock/native failures to a
structured source failure. `Ingress` disables only the derived native source;
the durable artifact remains authoritative.

### Tests and gates

- Added explicit demand/playback contract coverage for `ReaderBinding`.
- Added native cursor factory contract coverage and ABI enum/version checks.
- Added Rust tests for source/cursor shared ownership and retained frame handles.
- Repository validation now requires the explicit playback field and every new
  cursor/frame ABI symbol in Rust, C, and Dart.

### Next iteration

1. Link a real incremental Animated WebP decoder behind the cursor ABI.
2. Add Android `SurfaceProducer` registry and serial blit worker.
3. Connect native frame handles to the Android uploader without copying through
   MethodChannel.
4. Resolve frame budgets from live device memory and thermal telemetry.

## 0.10.0-dev.10 — reader binding and frame budgets

### Requested fix

- Replaced `ReadingDirection.leftToRight` in
  `pipeline/test/viewport_phase_test.dart` with the canonical `ltr` enum value.
- Added a repository regression gate that rejects the stale long-form value.

### Reader runtime binding

Added `ReaderBinding` as the application composition boundary for one reader
session. A single `ReaderObs` now drives `PipelineController`, demand
reconciliation, `ViewportResolver`, and playback synchronization. The demo app
uses this binding instead of wiring only the demand callback.

`Coordinator` remains the demand contract. `PlaybackCoordinator` is a separate
capability implemented by both live and fake coordinators, so non-playback
coordinators do not need dummy methods.

### Decoded/output budgets

Added `FrameBudget` and `FrameBudgeter` with independent decoded and renderer
output byte limits. Each limit has a current-page reserve. Non-current sessions
may use only the remainder and are trimmed in ascending demand priority.
Current-page resources are not silently discarded when the current page alone
exceeds a limit.

`FrameHolder` can now trim by bytes while respecting active claims.
`UploadSession` exposes output bytes and only trims an output when no present
claim exists. `LiveCoordinator` enforces the budget after reconciliation,
decode completion, and upload completion, and emits `frameBudget` telemetry
when bytes are released.

### Next iteration

1. Add native cursor/frame ABI and frame-handle retain/release ownership.
2. Add Android `SurfaceProducer` registry and serial blit worker.
3. Resolve frame budgets from device memory/thermal telemetry instead of fixed
   construction-time limits.

## 0.9.0-dev.9 — split APK and viewport playback gate

### Requested fixes

- Removed the two trailing commas inside `SourceStatus.values[...]` index
  expressions in `bridge/native_source.dart`.
- Android APK builds now go through `tool/build_android.sh` and always use
  `--split-per-abi`.
- CI builds split debug APKs instead of a single fat APK.

### Viewport playback integration

Added `ViewportResolver` and `ViewportState` with four phases:

- `idle`;
- `dominant`;
- `overlap`; and
- `continuous`.

For discrete PageView navigation, playback freezes only while both pages have a
significant overlap. It resumes as soon as either page becomes dominant. For
continuous/custom scrolling, presentation remains frozen until the interaction
returns to idle.

Added `PlaybackGate` and `LiveCoordinator.syncPlayback()`. The gate applies
freeze/resume changes only when state changes, freezes a running page before it
leaves the tracked viewport, and does not restart timers repeatedly for
identical viewport observations.

### Build and regression gates

- Added `tool/build_android.sh [debug|profile|release]`.
- Added `make android-apk`.
- `tool/check.sh --require-toolchains` now also builds split debug APKs.
- Repository validation checks split APK configuration, native source index
  syntax, viewport exports, and coordinator playback integration.

### Next iteration

1. Connect Reader viewport reports to `ViewportResolver` and the live pipeline
   binding used by the app.
2. Add decoded/output byte budgets with a reserved current-page allocation.
3. Implement native cursor/frame ABI and frame-handle ownership.
4. Add Android `SurfaceProducer` texture registry and serial blit worker.

## Android library shell and persistent shelf state

The app now exposes Home and Bookshelf as primary destinations. Home contains
update and reading-history card rails; Bookshelf contains source/category
filters, management deletion, recent/title/page-count/custom sorting and durable
custom reordering. Existing static/WebP/native diagnostics remain available
below the product sections for regression work.

SQLite schema version 3 persists custom categories, shelf/liked/collected flags,
category membership, source kind, custom order and explicit chapter read state.
The in-memory store implements the same contract. Existing version-1 databases
migrate in place.

Cover cards load their first page through the local-media byte boundary and use
`Image.memory`, so animated WebP/GIF covers can animate. A reusable download
waterline supports percent and completed/total page count. Details UI implements
preference toggles, chapter order reversal, read dimming and right-swipe restore
unread. Local imports without metadata continue to open Reader directly on long
press.

## 3.12 Android source networking and copyable diagnostics

Flutter platform hosts remain generated artifacts, but their product capabilities are now configured
by repository-owned tooling. `tool/configure_platforms.py` idempotently inserts the Android Internet
permission into the generated main manifest. Bootstrap, Android build and the repository Android run
entry all invoke this step, so release networking does not depend on Flutter's development manifest.

`HttpTransport` still owns ordinary HTTP byte ingress and does not move networking into Widgets. Its
default client can now use an explicit connection timeout and user agent, and socket failures include
OS error text and errno. `MangaDexSource` applies one bounded retry only to `ErrorCode.network`; source,
format and size failures are never retried as network transients.

The source UI captures the original error, `Failure.cause` and stack trace. Primary failures use a
bounded `SelectableText` diagnostics surface with long-press selection and explicit clipboard copy.
A failed host lookup is described as either missing Android application permission or a system DNS /
proxy / VPN path difference; browser reachability is not treated as proof that the App resolver works.


## 3.13 Authoritative chapter-download management

`ChapterDownloadService` now exposes a task stream rather than only a blocking command. Each
`ChapterDownloadSnapshot` carries source-composite chapter identity, comic/chapter labels,
completed/total pages, received/total bytes, a bounded phase and copyable failure text. The
persistent implementation computes this projection from the existing `DownloadRegistry`,
`DownloadSession` and promoted artifacts; it does not create a parallel downloader or progress
store. Terminal phases remain authoritative while late session callbacks drain.

Home, reading history and Bookshelf reuse the same `ComicCoverCard` and aggregate snapshots by exact
`sourceId + comicId`. Incomplete work dims the cover and displays a bottom-up completion waterline,
percent and completed/total pages. Complete coverage restores the original cover and shows only a
compact offline badge. A top-level Download Manager exposes per-chapter cancel, retry and confirmed
offline artifact deletion, with page/byte progress and selectable/copyable failure details. Offline
artifact deletion deliberately retains the saved comic, imported chapter metadata, reading progress
and explicit read state.

The memory fallback implements the same lifecycle and owns full page bytes before completion. Tests
cover progress publication, cancellation with retained partial progress, retry to completion and
manager deletion. Missing covers now fail asynchronously into a placeholder instead of throwing from
a Widget build; details mark chapters read before opening Reader, avoid duplicate titles, and expose
stable source-management, sorting, category-move and retry controls.

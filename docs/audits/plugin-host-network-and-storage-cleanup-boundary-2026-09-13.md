# Plugin-host network and structured cleanup boundary — 2026-09-13

## Result

The plugin host does not need a second copy of the application `NetLane`. The audit found three distinct network ownership classes:

1. **Plugin-management control plane** — `ExternalPluginController` repository index/descriptor/payload/update traffic. This is not Reader/download media traffic. It is bounded by HTTPS-only redirects, response-size limits and 15 s connect/idle timeouts. The controller now explicitly owns every active repository `HttpClient` and force-closes it during controller teardown, so a slow response cannot outlive the plugin-management owner.
2. **Plugin-runtime control plane** — browse/details/chapter/request-plan JavaScript/Kotlin work. Venera has one physical JavaScript context and therefore one invocation permit; Mihon uses the runtime's bounded `maxConcurrentInvocations`. Both retain invocation timeouts and close/cancellation barriers. These operations must not acquire the media `NetLane`: request-plan/control work can be required to discover the media request that the data plane will later execute.
3. **Media data plane implemented by a plugin socket** — source-owned whole-body fallback is still allowed only for real response transforms/client-state compatibility. It is not an independent network scheduler. `NetLane` first admits the physical transfer and creates the task `TaskControl`; `DownloadTransferOwner` then runs `DownloadJob`, which enters `SourceResourceTransport.openControlled()`. Direct source sockets and Venera/Mihon runtime fallback both receive that same control. The outer NetLane transport lease/read permit therefore accounts for the physical media task for the whole plugin fetch lifetime.

The important invariant is **admission ownership, not socket implementation**. rhttp/OkHttp/HttpClient may execute a source operation, but media concurrency stays owned by the composition `NetLane`.

## Mechanical evidence

- `NetLane` creates the active task and `CancelToken` before invoking the transfer-owner task callback; the task holds the transport lease and initial response-read permit.
- `DownloadTransferOwner` constructs `DownloadJob` only inside that admitted callback and passes the same token to `DownloadJob.run()`.
- `DownloadJob` passes its control into `ControlledTransport.openControlled()`.
- `ExternalPluginResourceTransport` forwards the control through request-plan resolution, direct transport and `ControlledComicResourceSource.loadResourceControlled()` runtime fallback.
- The source-resource regression now asserts that the runtime-transform path receives the identical scheduler control; the full source transport file passes 24/24.
- The plugin-management close regression injects a repository request blocked in `request.close()`, closes `ExternalPluginController`, and proves the controller force-closes the owned client; the manifest/controller file passes 9/9.

## Why plugin control-plane traffic must not be folded into NetLane

Venera `onImageLoad`/request-plan resolution can execute source-owned `Network.*` before a direct media request exists. Making that resolver acquire the same media lane from inside an already admitted/opening media task would create a nested-capacity dependency. Generic browse/details work is also not a physical media-transfer claim and has its own bounded runtime gate. The correct rule is therefore:

- generic/runtime control-plane work uses the plugin runtime gate;
- repository/install work uses the plugin-management controller lifecycle;
- actual Reader/download media work must already be inside a composition NetLane task, even when source compatibility requires the plugin runtime to fetch the body.

## Structured-storage cleanup debt

Schema 9 already provides the correct durable ledger for **replica migration**. `artifact_replica_migration` is progress-only state: `copying` keeps the source authoritative and a deterministic temp resumable; `cleanupPending` records exact source/destination/temp locators after authority has moved. Do not duplicate this state in a generic cleanup table, and do not delete `copying` temps during startup.

The remaining orphan class is ordinary atomic-write temporary data such as random `.zic-tmp-<timestamp>` files used by SAF/direct READY and partial materialization. Those names are not derivable after a crash, and SAF tree enumeration is too expensive and too weak an authority boundary for cold-start recovery.

The next storage stage should therefore add a **generic non-authoritative-temp cleanup ledger**, with these constraints:

- Record the exact temp locator before creating/writing it. The row is cleanup/progress state only and never artifact, replica, partial or download authority.
- A row must identify the storage root/access kind sufficiently to revalidate that the exact locator belongs to an owned Direct root or the currently proven SAF tree. Never delete by suffix scan or directory-wide pattern matching.
- On successful commit, delete the temp if it still exists; remove the debt row only after absence is confirmed. Missing temp is success. `accessDenied`/I/O failure keeps the debt row and never invalidates the target artifact.
- Recovery is **targeted and asynchronous**: after durable services are available, a bounded drainer lists only debt rows and performs exact-locator deletion through `StorageWriteScheduler`. It must not block normal cold startup or enumerate a SAF tree.
- The same drainer may retry schema-9 `cleanupPending` rows via the existing `_cleanupCommittedReplicaMigration()` path. `copying` rows are not generic garbage and remain untouched for resume.
- Final logical invalidation must continue to remove migration-owned temps and should also retire any generic temp debt owned by the invalidated operation when that ownership is known.

This is intentionally a cleanup mechanism, not lazy migration/retention policy and not another storage authority.


## Implemented follow-up: schema 16 cleanup debt

The proposed generic temporary ledger was implemented in the same review cycle as download-cache schema 16. `storage_cleanup_debt` is keyed by exact access locator and carries only storage-root, cleanup kind and timestamps. Atomic SAF hooks prove the debt is inserted before the provider temp is opened and removed only after the temp is absent; Direct structured/materialization temps use the same store-owned lifecycle. Store open schedules an asynchronous targeted drainer after construction; close joins any active drain before closing SQLite. Recovery tests cover blocked storage-write capacity (open still returns), exact Direct deletion, exact SAF deletion with zero SAF `list()` calls, inaccessible/different-tree retention, delete-I/O retention, automatic `cleanupPending` retry, and preservation of migration `copying` temps.

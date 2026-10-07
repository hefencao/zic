# Canonical download / force-reload ownership review — 2026-09-12

## Scope

This review covers explicit chapter download, whole-comic download, Reader force reload, and the canonical physical-media owner. It does not add a Canonical-cache delete UI or a bulk-delete command.

## Download command audit

The current chapter/whole-comic layering is compatible with canonical physical ownership:

- `WholeComicDownloadQueue` owns queue state and chapter aggregation only. It calls the existing chapter command and never creates a second physical transfer/session owner.
- A `ChapterDownloadSnapshot` may count canonical/verified physical residency in `completedPages`, but `isComplete`, `exactCompletedPages` and `pinnedPages` remain exact/manual-download facts. Canonical cache residency alone therefore cannot falsely complete a manual chapter or whole-comic job.
- `PersistentChapterDownloadService` acquires the physical session only after the required exact claim has gone through `CompositionDownloadTransferRuntime`. A canonical page can therefore join the existing physical owner instead of first creating an exact session.
- Explicit download completion still crosses `persistPromoted(exactId)` and exact pinning. Canonical physical-only bytes may satisfy the body with zero network/zero body duplication, but the command finishes only after the requested exact durable/manual state exists.

A new whole-comic integration regression starts with a current chapter that has only canonical physical cache residency. The queue does not consider it manually complete, then completes the chapter through the normal chapter command with zero network, materializes the current exact binding, and pins it.

## Force reload contract

Force reload is a presentation/source refresh command, not a delete-download command. The consistent contract is now:

| Current state | Force reload behavior |
| --- | --- |
| Unpinned Reader/auto cache | Quiesce the current physical task, retire stale physical READY/partial routing, reset the same physical session epoch, quarantine durable/equivalent restore, then reopen the source. A successful fresh generation may become the new ordinary cache authority. |
| Active explicit chapter/whole-comic download | Quiesce/cancel the currently admitted attempt, keep the existing required claim and the same physical `DownloadSession`, reset only its epoch, then re-admit that same physical owner. The explicit command still owns exact durable completion/pinning. No second retry/transfer owner is created. |
| Already explicitly downloaded / pinned exact page | Preserve the exact pinned durable/offline binding. Retire stale canonical physical routing and bypass all durable restore for the new physical epoch, fetch fresh source bytes into the same hot physical owner, but suppress the automatic cache commit for that fresh epoch. Reader force reload therefore cannot silently unpin, delete or overwrite a user download. Replacing the offline download remains an explicit chapter-download operation. |

The transient fresh-source quarantine is checked before `PartialDownloadHandoff` chooses canonical READY, canonical partial, exact READY/partial or verified-equivalent candidates. This closes the previous hole where force reload could reset the session and then immediately restore the same canonical body it was intended to bypass.

Pinned-state detection is exposed as a narrow optional cache-backend capability. Composition checks both the actual presentation `storageId` and, when that differs, the requested exact `DownloadId`; therefore a canonical/equivalent presentation carrier cannot accidentally make an already-downloaded current page look unpinned. Reader does not learn chapter/download state and does not own deletion policy.

## Why the pinned exact body is not automatically replaced

A manually downloaded file is explicit user-retention state; a Reader reload is only a presentation command. Automatically replacing that durable file would make the Reader command a second offline-download mutation owner and would be especially dangerous for structured export/download paths. The fresh physical epoch is therefore hot-only while the old pinned exact durable object remains retained. If a future product action is intended to replace the offline copy, it should invoke the chapter-download owner explicitly and make that replacement semantics visible to the user.

## Future Canonical cache deletion — evaluated, not implemented

The existing single-physical-file invalidation primitives can support a later Canonical-row or whole-auto-cache delete, but `ChapterDownloadService.delete()` is the wrong primitive because it also mutates manual task, placement and exact download state.

A future cache-delete command should instead build an ownership-aware physical `DeletePlan` from the authoritative cache-management projection:

1. Resolve each selected Canonical row to its physical READY/partial identities; Exact gap rows remain exact-cache targets.
2. Quiesce only active physical tasks that actually target those identities.
3. Remove canonical physical artifact bindings with `invalidatePhysicalArtifact` and physical partials with `invalidatePhysicalPartialDownload`.
4. Preserve pinned/manual exact bindings. Shared immutable bytes are physically removed only when the artifact has no remaining exact or physical reference; the existing artifact-object reference rules already provide this safety boundary.
5. Publish one management-projection invalidation after the batch commits. Do not implement deletion by iterating visible version rows or by calling chapter delete once per version.

This can later back both “delete this Canonical cache row” and “clear this comic’s automatic cache”. It should be a separate feature/transaction with its own confirmation and tests, not part of this force-reload/download audit.

## Focused validation

- `packages/pipeline_runtime/test/presentation_local_direct_read_test.dart`: 9/9, including pinned canonical force reload and requested-exact pin protection when the presentation authority differs.
- `packages/sessions/test/download_transfer_owner_test.dart`: 38/38, including active required transfer recovery on the same physical session.
- `packages/downloads/test/chapter_downloads_test.dart` + `partial_download_handoff_test.dart` + `promoted_artifact_cache_handoff_test.dart` + `whole_comic_downloads_test.dart`: 133/133 combined. This includes the whole-comic canonical physical-only regression, an active chapter force-reload regression proving the required claim remains on the same physical session, and a low-level physical invalidation regression proving a pinned exact binding remains readable.

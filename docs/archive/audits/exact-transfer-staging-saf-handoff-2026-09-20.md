# Automatic exact transfer checkpoint vs SAF placement audit (2026-09-20)

## Symptom and evidence

A local-folder Reader run exposed two apparently ~28s durable operations for the same exact page:

- a 3 MiB `transfer-progress-checkpoint` partial handoff: about **28.496s**;
- a 16.2 MiB promoted artifact handoff submitted about **0.391s later**: about **28.839s** total.

The final READY body was actually committed under App-private `offline_chapters/final/`. Timeline reconstruction showed that the promoted handoff finished only about **0.724s after** the partial store released the same exact-id mutation tail. Therefore the promoted artifact itself was not a 28s write; roughly 28.1s was queueing behind the preceding partial mutation.

Device SQLite also showed historical exact/physical partials under the configured SAF download tree while automatic READY cache bodies remained App-private. This is an ownership mismatch, not a Reader/NetLane/download-window problem.

## Root cause

`PersistentDownloadArtifactStore.storePartialDownload()` selected SAF whenever `safTreeIo + safTreeUri` were configured. `PartialDownloadHandoff` used that generic method for exact-fallback hot-transfer retirement/checkpoints.

That made a user-selected explicit download destination become the mutable staging root for an automatic Reader/cache checkpoint. The SAF transactional write (temporary document, chunked provider writes, commit/rename, metadata) held the per-exact `_artifactMutationTails[id]` serializer, so a later promoted artifact for the same id had to wait behind unrelated slow placement I/O.

The repository already had the correct split for canonical physical partials: automatic transfer checkpoints pass `preferDirectStaging: true`, while explicit final placement remains separate.

## Boundary after the fix

A narrow optional `TransferStagingPartialDownloadStore` capability now expresses only one intent: an automatic exact hot-transfer checkpoint prefers low-latency Direct staging.

`PartialDownloadHandoff` uses that capability for exact-fallback checkpoints when the backend supports it. Generic `PartialDownloadStore.storePartialDownload()` is unchanged, so historical/explicit SAF exact-partial storage and restore remain supported.

`PersistentDownloadArtifactStore` implements the staging capability with the App-private base `CacheLayout`, independent of a global SAF override or source-specific final placement. The authority switch follows the existing physical-partial migration discipline:

- never replace a longer authoritative prefix with a shorter staging copy;
- verify access to an old external/SAF partial;
- write the deterministic Direct partial and normal resume sidecar;
- commit the new exact partial index authority;
- register cleanup debt before retiring the old locator;
- on a failed replacement, keep the old indexed locator authoritative unless the new prefix reached a safe boundary.

Explicit chapter download remains unchanged: after transfer promotion, `PersistentChapterDownloadService` separately calls `mirrorPromotedToSafIfConfigured()` and later pins the exact records. SAF therefore remains a final/manual placement capability, not automatic checkpoint staging.

## Validation

Mechanical coverage includes:

- exact-fallback transfer checkpoint with SAF configured lands in App-private Direct staging and reopens correctly;
- an idle generic Direct exact-partial session, including one rooted at a source-specific POSIX download directory, is mechanically retired before automatic staging migrates the growing prefix back to the App-private base layout;
- progress-retention checkpoint uses the same Direct staging contract;
- equal historical SAF exact partial migrates to Direct staging and retires the old SAF body/meta;
- if that old SAF body cannot be deleted immediately, the new Direct locator remains authoritative while an `obsoletePartialSource` cleanup debt survives restart and retires the old body later;
- generic SAF exact-partial owner checks, foreground-yield behavior and stream-backed restore remain intact;
- canonical physical SAF→Direct checkpoint migration remains intact.

Focused results:

- `chapter_downloads_test.dart` + `partial_download_handoff_test.dart`: **138/138**;
- Downloads full package: **442/442**;
- targeted analyzer: **0 errors / 0 warnings** (repository-existing info lints remain);
- Dart structure and `git diff --check`: pass.

Canonical device validation used `./tool/build_android.sh profile`, which rebuilt release native media for the Profile APK, followed by `python3 tool/prepare_reader_device_test.py --mode profile`. The helper installed `arm64-v8a`, verified display 0, and reached authoritative Home in about 1.26s. During validation we also proved that this MIUI device does not reliably deliver the old `adb shell input -d 0 tap ...` form; harmless Home→Bookshelf→Home control round-trips established `adb shell input touchscreen -d 0 tap/swipe ...` and `adb shell input keyboard -d 0 keyevent ...` as the working source-first forms. Earlier no-op tap attempts were discarded and the repository device skill/helper were updated so they cannot be mistaken for product failures later.

With valid input, `.log/exact-staging-profile.jsonl` entered the 21-page local-folder Reader through `resume-local`: current zero-based page16 reached first frame in about **128ms**, six speculative transfers started, and there were zero task failures. Those local 17–20MiB pages completed fast enough to become resident sources, so no unfinished exact partial remained. A second valid Profile run, `.log/raiden-exact-fallback-profile.jsonl`, used a 157-page single-chapter `venera:ehentai` comic with **zero version relations**, therefore exercising exact-fallback rather than canonical physical ownership. Current zero-based page48 reached first frame in about **115ms**; two uncached speculative exact pages completed with ordinary final handoffs of about **97.944ms** and **97.803ms**, with zero failures and no observed `zic-saf-path` work. This is useful evidence that the promoted-artifact owner itself is not a 28s operation once the erroneous SAF checkpoint queue is absent.

Neither valid Profile workload naturally left an unfinished exact partial: the device had zero exact `CacheState.partial` rows, local bodies completed into resident sources, and the available zero-version-relation remote pages were only tens to hundreds of KiB. Therefore these runs do **not** serve as a direct Android timing benchmark of `storeTransferPartialDownload`. We deliberately did not clear cache, edit the user database, throttle transport, or otherwise manufacture that branch. The performance conclusion is bounded to the device-proven old 28s SAF serializer blockage, the current ~98ms exact-fallback final-handoff control, and deterministic regressions proving that automatic exact checkpoints now perform zero SAF body writes while preserving migration/cleanup authority.

Do not respond to this issue by widening Reader windows, changing 3/7 or 2/1 policy, increasing NetLane concurrency, or making SAF the cache authority.

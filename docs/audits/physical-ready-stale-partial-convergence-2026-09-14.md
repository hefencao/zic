# Physical READY / stale partial convergence audit — 2026-09-14

## Trigger

Reader progress validation found canonical `single2:24` with a 6,415,684-byte local `.part` whose WebP RIFF-declared full length was also 6,415,684 bytes. That initially looked like a complete body stranded in partial state. SQLite and Trace showed a different fault: the same `PhysicalMediaId` already had a readable READY `physical_media_artifact` and `artifact_object/artifact_replica`; the old `physical_partial` row and body had merely survived promotion.

Trace for page24 recorded `artifactPromoted`, `bound-ready-authority` / `local-completion-short-circuit`, `networkAdmissionRequired=false`, and `canonical-bound`. The stale partial therefore was not needed for playback or durability. It was conflicting inventory left behind by an unreachable cleanup branch.

## Root cause

`PartialDownloadHandoff.restoreInto()` deliberately checks canonical READY before cold partial. When READY exists it binds the immutable body and returns. The older cleanup inside `openPhysicalPartialDownload()` — “if a READY physical artifact exists, delete this partial” — consequently cannot run for exactly this historical READY+partial shape. READY bind/recovery paths could likewise establish the physical artifact without retiring an older row.

The invariant is now explicit: for one canonical `PhysicalMediaId`, a readable READY artifact dominates mutable partial inventory. A same-key partial may be temporarily present during mutation, but is not a second long-lived progress/body authority.

## Persistent-owner fix

`PersistentDownloadArtifactStore` now owns convergence at three boundaries:

- physical READY bind schedules targeted redundant-partial retirement;
- opening a verified physical READY schedules the same retirement, repairing historical rows on normal access;
- store open starts an asynchronous SQLite-only intersection sweep of `physical_media_artifact` and `physical_partial`, so old rows converge even if the corresponding Reader page is never opened. The sweep is not awaited and does not list Direct or SAF trees.

Each per-id retirement re-enters the existing physical-artifact then physical-partial serialization domains, verifies the currently bound artifact id still matches the READY generation, and skips a currently borrowed hot partial. Actual deletion uses the shared `StorageWriteScheduler`. The body and sidecar are removed and confirmed absent before the DB partial row is retired. If cleanup cannot be proven, the row remains as retry authority; no row-first orphan and no Reader/App-exit cleanup contract are introduced.

Combined testing exposed a lock-order bug in the first implementation: deferred READY LRU touch acquired a storage-write lease before waiting for the physical-artifact mutation tail, while retirement held artifact/partial serialization and then waited for storage-write capacity. That is an AB/BA deadlock. Deferred touch was changed to enter physical-artifact serialization first and acquire its storage-write quantum inside that domain, matching the artifact→storage order used by retirement and existing destructive artifact work.

## Regression evidence

Three focused regressions cover: partial-before-READY bind, historical READY+stale-partial repaired by READY open, and cold store open repairing historical overlap without any artifact read. Full Downloads finishes **404/404**. Targeted analyzer reports no errors or warnings (existing info lints remain).

## Device evidence

A fresh profile was installed with `adb install -r`; user data remained intact and battery saver was off. Before launching it, SQLite had exactly **10** residual `physical_media_artifact ∩ physical_partial` rows: **4 App-private Direct + 6 SAF**. No Reader was entered.

After Home-only cold startup, 5 remained at roughly 8 seconds while startup/local-read pressure was active; after another 12 seconds the intersection was **0**. Every one of the ten old `.part` paths was independently checked and absent. `physical_partial` count fell **52 → 42**, while physical READY artifact count remained **72**. A later force-stop/cold reopen kept the intersection at **0**.

Home remained responsive: bootstrap `initialize-complete` was about **87 ms**, services handoff revision fast-path about **449 ms**, and snapshot write about **765 ms**. This supports the intended property that the historical convergence sweep is background storage maintenance, not an App-start barrier.

This result is independent of the Reader single-scale progress fix. Local RIFF total-length inference remains projection-only and never authorizes READY, seal, resume, promotion, or stale-partial deletion.
## READY-dominant management and capacity projection

The background sweep closes physical storage eventually, but management cannot expose a temporary double fact while that I/O is pending. The page-level Download Manager projection already did the right thing (`artifact` is selected before `partial`). Persistent cache usage did not: it summed every `physical_partial`, so a READY+partial overlap could temporarily double-charge bytes/entries and make trim treat stale recovery inventory as capacity pressure.

The persistent store now filters same-`PhysicalMediaId` partials out of `inspectArtifacts()` bytes/entries and reserved partial bytes. Trim rechecks READY dominance inside the existing physical-artifact→physical-partial serialization domain and skips a dominated partial rather than evicting it as an independent cache object. Explicit clear may still remove the redundant body/sidecar because clear is already a destructive persistent-maintenance boundary, but that removal is not reported as another cache eviction. No management/read path gained cleanup ownership.

A focused regression seeds READY first and then injects a stale same-key physical partial while the store remains open. Usage is unchanged, trim at the READY-sized limit performs zero eviction and leaves the stale row for the normal retirement owner, and clear releases the READY-sized logical inventory once while physically removing the redundant partial. The existing canonical Download Manager regression was extended with the same overlap and still reports one READY page, zero partial pages and the READY byte count. Full Downloads is **406/406** after the follow-up read-ownership regression; targeted analyzer has 0 errors/warnings (existing info lints only).

The preserved real-device pre-sweep SQLite snapshot provides a non-synthetic capacity check: 52 physical partial rows held **196,048,225 B**, of which the 10 READY-overlap rows accounted for **60,818,652 B** (31.02% of raw partial bytes). Raw physical rows/bytes were 124 / 1,386,306,857 B; READY-dominant projection is 114 / 1,325,488,205 B before any stale-body deletion. The freshly installed profile's current DB has 43 partial rows, 74 READY physical artifacts and **0** overlap.
## Read-path cleanup ownership audit

A follow-up inventory of every production `physical_partial` consumer found one remaining ownership leak: `openPhysicalPartialDownload()` is a read/recovery probe, but its historical READY-dominance branch synchronously called `_removePhysicalPartialRecord(...)`. That branch was usually bypassed because `PartialDownloadHandoff` probes READY first, which is also why old overlaps could survive; nevertheless, leaving it in place created a second cleanup entrance outside the unified persistent retirement path.

The read branch now returns `null` as soon as same-key READY is observed and only schedules `_scheduleRedundantPhysicalPartialRetirement(...)`. A regression blocks the shared `StorageWriteScheduler`, performs the partial read, and proves the call returns while the stale row/body still exist and one maintenance write waits behind the blocker. Releasing the blocker lets the existing artifact→partial→storage-write owner remove the body/row while READY remains readable. This makes the boundary mechanical: reads suppress dominated partial authority immediately, but only persistent maintenance deletes it.

The remaining production consumers classify as persistent mutation/validation (store, adopt, borrowed-session sync, invalidate), persistent cleanup (targeted retirement/open sweep), canonical backfill coverage proof, or READY-dominant read projection. Production borrowed durable sessions inject `DownloadCacheMutationOwner` back into the persistent store; the sessions-layer direct `PhysicalPartialIndex` path remains only a generic compatibility fallback rather than a second production store owner. Targeted analyzer remains 0 errors/warnings (existing info lints only), and the full Downloads suite passes after the new ownership regression.

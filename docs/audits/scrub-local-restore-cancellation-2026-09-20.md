# Scrub local-restore cancellation audit (2026-09-20)

## Trigger

A page seen shortly before leaving Reader showed one slow first load. The original `01-58-11` trace also contained a repeatable local-preparation long tail after large seek/scrub movement. These are related only at the scheduling boundary and must not be conflated with the later page-383 cold source-open cost described below.

## Proven local-preparation failure

In `pipeline-reader-8`, the idle 3/7 window reopened around 846.663s after a long scrub. Page 68 entered local preparation immediately as next2, but `physical-local-prepare` did not retire until 847.549s (`prepareMicros=884669`). The underlying durable miss proof was not an 884ms DB/filesystem lookup: once `PartialDownloadHandoff.restoreInto()` actually began, owned checkpoint, physical artifact open and historical binding completed in roughly 7.2ms total. Nearby pages showed the same ~0.9s prepare lifetime.

`DownloadTransferOwner` intentionally caps real local-prepare operation lifetime at two slots. Destructive scheduler preemption remains current-only; lowering that threshold for next/next2 would turn rapid viewport movement into a cancellation storm. The missing boundary was lower: `DownloadSession.restore(control:)` received the scheduler `TaskControl`, but generic `Artifact.restore()` dropped it. If restore fell through to whole-file CRC recovery, `Artifact._rehash()` ran the complete file in `Isolate.run`, so a page whose scrub demand had already disappeared could keep one of the two local-prepare slots until CRC completion.

## Fix boundary

Scheduler-owned restore now forwards `TaskControl` into `Artifact.restore`. Ordinary artifact restore/seal keeps the existing background `Isolate.run` path. Only controlled restore uses a cancellable CRC worker isolate; task cancellation kills that worker and throws the existing `ErrorCode.cancelled` boundary. Storage observes cancellation only; it does not inspect priority or make scheduling decisions. `DownloadSession` continues to treat cancelled restore as deferred/idle rather than terminal corruption, and durable files remain untouched for the next owner attempt.

`DownloadTransferOwner` additionally traces local-preparation admission/retirement so queue wait and active operation time are separable from the old aggregate `prepareMicros` value. This is diagnostic only and does not alter max2, 3/7, NetLane, or current-only destructive preemption policy.

## Regression and device validation

Focused tests cover cancellation of an in-flight background rehash, DownloadSession cancellation recovery, and the owner invariant that withdrawing two stale preparations releases both max2 slots to a new-window next2 demand. Results: storage artifact 26/26, DownloadSession 87/87 and DownloadTransferOwner 40/40 (Sessions tests use the repository's Linux sqlite preload requirement).

Fresh Profile on Raiden preserved the same cache and scrubbed the same 424-page animated WebP Reader from page 384 to 82 and then to 280 via the Reader seek control. In `.log/post-rehash-scrub.jsonl`, two scrub-obsolete active preparations retire with `cancelled=true` in about 53.0ms and 52.8ms. The reopened window retains rank continuity; the maximum observed queue wait is about 116.8ms rather than the previous ~0.9s stale-slot hold. A 323ms READY restore is not cancellation leakage: about 103ms is queue wait and about 220ms is real active recovery of a 7.7MiB durable prefix.

## Separate final-page cold path

The later `03-00-33` trace identifies the actual last page before exit as zero-based page 383 in `pipeline-reader-2`. Its local preparation is already fast (`prepareMicros≈21.6ms`) but mount-to-first-frame is about 2.622s. The page's request-plan task starts while it is next2 and dynamically migrates 800→820→900→1000. Its 2.626s total runtime-gate wait is mostly pre-current time behind the physically single Venera JavaScript context; after the viewport commits page 383 current, the gate hands over within roughly 30ms. The remaining visible cold cost consists of the first source plan/runtime invocation (~573ms), direct host open (~584ms), arrival of a decoder-usable WebP prefix, and first-frame presentation. Request-plan cache behavior is correct for this first successful resolve, and no duplicate plan/cache owner was found. Do not claim the local-restore cancellation fix removes this distinct cold-source cost, and do not compensate by increasing Venera runtime concurrency, lowering 3/7, changing 2/1, or weakening current ownership without new evidence.

# Scrub local-restore cancellation audit (2026-09-20)

## Trigger

The original user report was that the page seen shortly before leaving Reader had one unusually slow first load. Re-reading `01-58-11` by Reader-session order identifies that report with the **last Reader session, `pipeline-reader-8`, zero-based page68**, not with later synthetic page383 experiments. Page68 is therefore the acceptance sample for this regression.

## Proven local-preparation failure

In `pipeline-reader-8`, the idle 3/7 window reopened around 846.663s after a long scrub. Page 68 entered local preparation immediately as next2, but `physical-local-prepare` did not retire until 847.549s (`prepareMicros=884669`). The underlying durable miss proof was not an 884ms DB/filesystem lookup: once `PartialDownloadHandoff.restoreInto()` actually began, owned checkpoint, physical artifact open and historical binding completed in roughly 7.2ms total. Nearby pages showed the same ~0.9s prepare lifetime.

`DownloadTransferOwner` intentionally caps real local-prepare operation lifetime at two slots. Destructive scheduler preemption remains current-only; lowering that threshold for next/next2 would turn rapid viewport movement into a cancellation storm. The missing boundary was lower: `DownloadSession.restore(control:)` received the scheduler `TaskControl`, but generic `Artifact.restore()` dropped it. If restore fell through to whole-file CRC recovery, `Artifact._rehash()` ran the complete file in `Isolate.run`, so a page whose scrub demand had already disappeared could keep one of the two local-prepare slots until CRC completion.

## Fix boundary

Scheduler-owned restore now forwards `TaskControl` into `Artifact.restore`. Ordinary artifact restore/seal keeps the existing background `Isolate.run` path. Only controlled restore uses a cancellable CRC worker isolate; task cancellation kills that worker and throws the existing `ErrorCode.cancelled` boundary. Storage observes cancellation only; it does not inspect priority or make scheduling decisions. `DownloadSession` continues to treat cancelled restore as deferred/idle rather than terminal corruption, and durable files remain untouched for the next owner attempt.

`DownloadTransferOwner` additionally traces local-preparation admission/retirement so queue wait and active operation time are separable from the old aggregate `prepareMicros` value. This is diagnostic only and does not alter max2, 3/7, NetLane, or current-only destructive preemption policy.

## Regression and device validation

Focused tests cover cancellation of an in-flight background rehash, DownloadSession cancellation recovery, and the owner invariant that withdrawing two stale preparations releases both max2 slots to a new-window next2 demand. Results: storage artifact 26/26, DownloadSession 87/87 and DownloadTransferOwner 40/40 (Sessions tests use the repository's Linux sqlite preload requirement).

Fresh Profile on Raiden preserved the same cache and scrubbed the same 424-page animated WebP Reader from page 384 to 82 and then to 280 via the Reader seek control. In `.log/post-rehash-scrub.jsonl`, two scrub-obsolete active preparations retire with `cancelled=true` in about 53.0ms and 52.8ms. The reopened window retains rank continuity; the maximum observed queue wait is about 116.8ms rather than the previous ~0.9s stale-slot hold. A 323ms READY restore is not cancellation leakage: about 103ms is queue wait and about 220ms is real active recovery of a 7.7MiB durable prefix.

## Same-page post-fix acceptance

The original bad page68 physical download identity is `identity:<7a820ea786f07ec3,783>`. In `01-58-11`, while still next=820, its `physical-local-prepare` consumed **884.669ms** before `downloadStarted`; it was a local hydration miss with `networkAdmissionRequired=true`. Network/source work therefore started late, and when page68 mounted its first frame still took **621.968ms**. A remount seconds later was only 22.327ms, proving the one-off stall was preparation/startup timing rather than a permanently slow decoder.

After `8c7ac8b5`, current-main Profile `.log/current-main-page68-regression-check.jsonl` deliberately stresses the same 371-page Reader with SeekBar 242→33→68 before a normal y=900 page turn. The **same physical identity** is still not a trivial complete-cache case: it restores a 12,566,220-byte durable prefix from a 19,624,776-byte body and still reports `networkAdmissionRequired=true`. Its local-preparation lifecycle now waits **26.102ms** in the queue, runs **113.294ms** active and retires in **139.397ms** total (`prepareMicros=139.305ms`), then starts network at next=820. When zero-based page68 is later mounted, `firstFrameReady` arrives in **32.234ms**, before the page is promoted to current. Across 48 local preparations in the stress run, median `prepareMicros` is about **39.36ms** and maximum **226.87ms**; the former ~0.9s stale-slot hold does not recur.

This closes the original regression on the exact page/physical identity rather than on a substitute cold page. The later `03-00-33` page383 sample is a separate synthetic cold-source diagnostic and must not be described as the original “last page before exit” bug.

## Contract history

The underlying mismatch predates the immediate symptom. `99243721` introduced the bounded max-two local-preparation queue. `1db735de` later added priority preemption by cancelling `_LocalPreparationControl`, with comments explicitly treating a preempted restore as an operation that must unwind before its physical slot is free. The storage `Artifact.restore()` path, however, still performed whole-file CRC recovery without observing that TaskControl, so logical cancellation could not promptly retire the physical operation. `8c7ac8b5` completes that existing contract by carrying cancellation into controlled restore/rehash; it does not add a Reader special case or widen concurrency.

## Regression-window attribution

The visible regression appeared after the 2026-09-19 rounds, but the cancellation defect itself was not introduced there. Git history shows that `DownloadSession.restore()` started accepting `TaskControl` in `99243721` (2026-09-05), while `Artifact.restore()` still had no TaskControl parameter through `8c7ac8b5^`. Priority-driven local-preparation cancellation was already production behavior by `1db735de` (2026-09-08). The broken seam was therefore latent for roughly twelve days: upper layers could cancel a stale preparation, but a restore already inside generic whole-file CRC recovery could not physically unwind.

The last healthy device trace and the original bad trace exercised very different cache states. In `02-48-21`, 149 physical local preparations contained 148 `local-completion-short-circuit` and only one `local-hydration-ready`; median/max prepare time were about 11.15/150.79ms and none exceeded 300ms. In `01-58-11`, 131 preparations contained only 70 short-circuits, plus 49 misses and 12 partial restores; 13 exceeded 300ms, 10 exceeded 700ms, and the maximum was about 4.715s. Page68 and several neighbors all accumulated roughly 0.9s before their actual `restoreInto()` probes began, showing a shared max-two queue hold rather than per-page I/O.

This also rules out the most tempting recent attribution. The original bad trace contains zero `bound-historical-ready-authority` events, so the historical READY branch added by `93f2fbf7` was not the path that delayed page68. `d792cfd6` changed ingress attachment, and `01b92c02` changed stale-presentation continuity; neither changed the storage restore cancellation seam. `878bc4d9` changed resident/cache replay behavior and can affect which cache states are encountered, but it likewise did not make `Artifact.restore()` cancellable or alter the max-two owner contract. These rounds may have changed exposure frequency and the accumulated cache/partial mix, but they are not the origin of the cancellation defect.

Post-fix stress confirms the fix is not being hidden by a more favorable cache state. `current-main-page68-regression-check.jsonl` still contains 25 local-hydration misses and 8 partial restores, including the same page68 physical identity with a 12,566,220-byte durable prefix that still requires network continuation. Across 48 preparations the median is about 39.36ms, the maximum about 226.87ms, and none exceed 300ms. The old >700ms stale-slot tail disappears even though non-complete local restores remain common.

## Separate synthetic cold-source diagnostic

The later `03-00-33` page383 sample has fast local preparation (`prepareMicros≈21.6ms`) but a first-time Venera/source-open cold tail. It was produced during post-fix stress testing and is intentionally kept separate in `cold-webp-first-frame-venera-plan-2026-09-20.md`. Do not compensate for it by increasing Venera runtime concurrency, lowering 3/7, changing 2/1, or weakening current ownership without a new user-visible reproduction.

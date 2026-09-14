# Reader bidirectional target preupload and device-validation audit — 2026-09-13

## Scope

This audit closes two test-attribution errors and the paged reverse-target first-frame gap discovered while validating the current `feat/version-canonical-owner` worktree. It does not change Reader waterlines, the 3/7 stable browsing-direction classifier, network/cache authority, refresh-rate policy, or lifecycle ownership.

## Build-mode attribution

The severe Animated WebP regression observed during device testing was caused by installing `tool/build_android.sh debug`, which rebuilds the Rust `media_core` in debug mode as well as Flutter in debug mode. With that native binary, frame decode was roughly 465 ms median / 509 ms p95. Reinstalling optimized native media restored the same cached workload to 404 samples with native decode p50 43.415 ms, p95 46.014 ms, and max 71.149 ms.

Cold-start timing had a second, independent build-mode trap. With debug Dart but release native media, three force-stop starts were 2.837–3.220 s and the 320,327-byte gzip Home snapshot (3,311,253 JSON bytes after expansion) appeared to require 1.255–1.334 s. A direct device read of the stored file was about 30 ms. Rebuilding Flutter in profile mode while retaining release native media reduced the identical snapshot restore to 87/99/99 ms and Android cold-start `TotalTime` to 772/812/993 ms; the visible Home window was 164/168/227 ms. Therefore no Home snapshot production change is justified by the debug-Dart timings.

Device performance conclusions MUST use profile/release Dart plus release native media. Debug builds remain valid for functional tracing but not absolute startup/decode CPU timing.

## Reverse target gap

Stable browsing direction intentionally uses 3/7 hysteresis. On the first two reverse page commits, the actual gesture target can therefore still have `PageRole.previous`. The old first-frame preupload policy admitted only `PageRole.next`, making a genuine reverse target wait until transition/current promotion even though `targetCoverage` already identified it.

The policy now keys the interaction-gated 820 demand to the actual adjacent `targetCoverage.pageIndex`. It admits `next` or `previous` only while the viewport is dragging, scrolling, or settling and only when decode work already exists. It does not create idle previous upload, change the 3/7 classifier, widen 7/3 encoded work, widen the 2/1 stable decode window, admit next2, or enable vertical hidden animated upload.

## Device result

The controlled workflow was: enter the cached animated chapter, make three committed moves in one direction, leave Reader, confirm Home interaction, re-enter the same reading-history item, then commit three moves back. The new navigation analyzer reconstructs committed gestures from trace facts rather than Android accessibility nodes.

Forward mount-to-first-frame samples were 98.1 / 64.0 / 43.5 ms. On the reverse leg, the first two committed targets were still classified `previous` because stable `readDirection` remained +1; they completed in 52.3 / 33.4 ms. After the second reverse commit the stable direction flipped to -1, so the third reverse target became `next` and completed in 44.4 ms. The earlier device run was approximately 101.4 / 118.0 / 17.0 ms, matching the former wait-for-direction-flip shape.

`mountToFirstFrameMicros` includes PageView gesture/settle and is not by itself a media-decode metric. The classification above is supported by the corresponding `pageTransition`, `policyDecision.readDirection`, target page mount, output prewarm, and first-frame events.

## 2026-09-14 local READY priority-wake follow-up

A later profile regression exposed a separate delay underneath the already-correct previous-target upload policy. In `.log/zic-debug-trace-2026-09-14T09-18-50.jsonl`, reverse turn 78→77 still began as `previous` under stable `readDirection=+1`, but took 1522.3 ms mount-to-first. Page 77 was a canonical durable READY body and `physical-local-prepare` eventually reported `networkAdmissionRequired=false`; nevertheless preparation lasted 6,141,720 µs and the first frame arrived roughly 1.33 s after `pageCurrent`. This ruled out gesture geometry, origin transport and native decode as the primary cause for that sample.

The shared `ArtifactCacheReadScheduler` already sorted pending work from a live priority callback, but a queued request was only re-pumped by unrelated lease/cancellation events. `_LocalPreparationControl` likewise exposed only `TaskControl`, so a background READY request promoted to transition/current could carry the new numeric priority without waking the pending local-read queue. The fix reuses the existing `PriorityObservableTaskControl`: local preparation publishes scheduler-owned rank changes, and `ArtifactCacheReadScheduler` subscribes only while that request is pending and immediately re-pumps on a change. Subscription ends on grant/cancel/removal. No admitted physical read is cancelled or reopened, and no Reader eligibility gate, second local scheduler, local-preparation capacity increase, 3/7 download change, 2/1 decode change, NetLane change or UploadDemand expansion was introduced.

Focused scheduler tests are 9/9 and `DownloadTransferOwner` 39/39; full Sessions and Downloads suites exited successfully, affected analysis has no error/warning, and a fresh profile APK was installed with `adb install -r`. The required bidirectional device workflow then produced `.log/zic-debug-trace-2026-09-14T09-41-29.jsonl`. Its previous-role committed turns are 40.7 / 218.2 / 49.2 ms. The 218.2 ms sample contains a 209.0 ms gesture/settle interval; its presentation frame arrives about 13.5 ms after `pageCurrent`, so it is not the former post-commit local-I/O stall. In the old problematic Reader window local preparation min/median/max was approximately 268 / 1640 / 6148 ms; the comparable new window is approximately 11 / 180 / 254 ms, while the fresh re-entry window starts around 14 / 30 / 37 ms. Native WebP decode remains in the optimized profile range and the validation trace has zero task failures.

This closes the local READY reverse-turn performance line. Long-lived background origin streams in the same trace are not evidence that this page-turn path needs narrower prefetch or another scheduling gate; any next performance change must start from a new user-visible reproduction and trace.

## Test workflow

A versioned AgentDock skill now lives at `docs/skills/zic-reader-device-performance/SKILL.md`. It requires build-mode verification, trace-backed Reader lifecycle evidence, dynamic Home-node selection instead of fixed cover coordinates, an exit/re-entry bidirectional sequence, and host-side temporary screenshots/UI dumps. `tool/analyze_reader_navigation_trace.py` reports the stable-direction role at each committed gesture; `tool/test_reader_navigation_trace_analyzer.py` guards the PageView bounce case and is wired into `tool/check.sh`.

The dev.281 source guard was updated from the obsolete `pagedNextPreupload` implementation token to the current active-target contract and still requires the vertical hidden-static upload deferral to wrap the final UploadDemand gate.

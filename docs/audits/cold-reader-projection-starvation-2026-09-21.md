# Cold Reader follow-up: projection microtasks starve platform events

## Scope correction

The previous service-handoff fix removed a real closed-owner defect, but did not solve all cold-entry loading delays. Its device smoke waited for services and therefore did not validate the user's early-entry experience. Preserve that safety fix; do not resume binding bootstrap services merely to shorten a preparation metric.

User's replacement `.log/zic-debug-trace.jsonl` is preserved as `.log/cold-reader-repeat-before.jsonl`: 217,433 bytes, 482 events, SHA256 `fc2e37e373481f3974a373d6ef8132bcf748dd01762d236032dc585252609be5`.

## New evidence

- Click/deferred loader push: 2.044s. Durable services ready: 3.212s.
- Reader prepared: 5.004s. `serviceHandoffMs=2740`, `loadChapterMs=215`, `totalPrepareMs=2957`, 26 verified mappings, local prewarm enabled. The preparation still includes Home adoption/reconciliation, not only service construction.
- Page 310 mounts: 5.029s. Its full 16,127,124-byte durable body is promoted cache-resident at 5.046s, with deferred replay ingress.
- Several unrelated handoffs, checkpoint probes and first replay reads all complete near 6.545s, reporting approximately 1.50s waits. A UI frame reports 1,809,803us vsync overhead with only 3,702us build and 703us raster work.
- First-frame timing reports 1,516,871us source wait but only 39,813us native decode. First frame appears at 6.637s: about 4.59s after the click.
- There are no `taskFailed` events and no network download-start events. The earlier closed-service mechanism is not the explanation for this run.

Fresh startup log `.log/cold-reader-repeat-live.log` independently shows a 38-entry targeted projection scan taking 850ms (Home elapsed 4921–5771ms), followed by authority recomputation. Storage snapshot encoding already runs in an isolate; its observed elapsed time can include delayed callback delivery and is not proof it blocked the UI for that whole interval. This log does not establish a successful early Reader tap; use it as startup-work evidence only.

## Confirmed implementation defect

`PersistentChapterDownloadService.inspectMany` uses `_inspectManyFromRecords` and `_buildSnapshot`. The page loops await cache/SQLite-backed Futures, which frequently complete immediately. These awaits drain as microtasks, not event turns. A large batch can therefore starve platform replay callbacks, timers and UI delivery despite appearing asynchronous.

A deterministic warm-storage test schedules a timer, awaits a 512-page projection, and requires the timer to have run before projection completion. Before the fix it fails with `eventTurnRan=false`, matching the event-loop starvation mechanism. This does not depend on a wall-clock performance threshold.

## Change

Projection page walks now use a computation budget shared across chapters. After at most 64 page visits or an observed 4ms slice, the loop awaits a zero-delay event turn and resets its budget. Single-entry snapshot calculation has the same bounded behavior. The time check is cooperative, not a hard latency guarantee for an individual page operation or synchronous index materialization.

This is neither network eligibility nor Reader-state gating. Store invalidations remain enabled, NetLane keeps scheduling authority, and admitted reads retain their owner until completion. Home's existing concurrent-event merge still prevents the delayed scan result from overwriting newer chapter events.

`inspectMany` now emits `targeted-projection-built` timings for indexed-record load, physical-state load, snapshot projection and total duration, so later traces can attribute background work instead of mislabeling a common event-loop stall as slow file I/O.

## Verification

- `.log/cold-projection-red.log`: runnable regression fails before production change.
- `.log/cold-projection-green.log`: regression passes after event-turn yielding.
- `.log/cold-projection-focused.log`: **109 download service tests pass**, including one large chapter and 128 small chapters sharing the same budget.
- `LD_PRELOAD=/lib/x86_64-linux-gnu/libsqlite3.so.0 bash tool/check.sh --require-toolchains` passes on the first full run for this change: **27 suites / 1,914 Dart/Flutter tests**, 3 existing skips, **22 Rust tests**, analysis/ownership/documentation/platform checks and all three debug APK ABIs. Evidence: `.log/cold-projection-final-check.{log,exit}`.
- `bash tool/build_android.sh profile` built all three profile APK ABIs with release native media; `.log/cold-projection-profile-build.log`. `bash tool/check_android_native.sh` passed after that build as well. No `dart format` was run.

## Device observations after the fix

No uninstall, data clearing, cache clearing or artificial service delay was used. Each exact APK was installed with `python3 tool/prepare_reader_device_test.py --mode debug|profile` / `adb install -r`. Harmless Bookshelf/Home selected-state checks proved display-0 input delivery before Reader tests. Independent cold-entry samples subsequently force-stopped and relaunched the app; they did **not** use the helper's durable-readiness gate before tapping. Early probes used history-card bounds resolved from the immediately preceding Home UI; the exported chapter identity and frame events independently validate which Reader actually opened. Source-first display-0 input was used throughout.

Debug observations:

| Export (`.log/zic-debug-trace-2026-09-21T…jsonl`) | Tap | Core ready | First frame | Tap → first | Early? |
| --- | ---: | ---: | ---: | ---: | --- |
| `10-04-22` | 0.777s | 2.678s | 4.717s | 3.940s | Yes |
| `10-08-46` | 3.271s | 2.404s | 5.217s | 1.946s | No |
| `10-09-00` | 3.481s | 2.421s | 5.324s | 1.844s | No |

All three presented the same chapter at its current durable resume index **275**, with no `taskFailed` events. The early sample's targeted scan finishes at 6.336s, after the first frame; source callbacks no longer require the whole scan to finish. A discarded attempt (`10-07-29`) contains **no Reader entry** and is not counted. The two later debug probes re-resolved the new process's Home tree, which took them past core readiness; they are not early-entry proof. See `.log/cold-projection-early-live.log`, `.log/cold-projection-sample-{2,3}.{json,log}`.

Profile Dart + release native, three independent early-entry samples:

| Export (`.log/zic-debug-trace-2026-09-21T…jsonl`) | Tap | Core ready | First frame | Tap → first | Service handoff |
| --- | ---: | ---: | ---: | ---: | ---: |
| `10-14-33` | 0.477s | 0.696s | 0.955s | **479ms** | 213ms |
| `10-14-46` | 0.412s | 0.653s | 0.864s | **451ms** | 232ms |
| `10-14-58` | 0.511s | 0.732s | 0.958s | **446ms** | 211ms |

All three taps precede core readiness. All produce frames for the expected chapter, page 275, with zero `taskFailed`. First source waits are 74/19/73ms; first native decodes are 60/52/49ms. The 38-entry projection scans finish at 1.329/1.351/1.404s, **after** first presentation in every run. Maximum observed Reader vsync overhead is 57/55/49ms, not the 1.81s freeze in the supplied debug trace. Raw evidence and protocol: `.log/cold-projection-profile-{1,2,3}.{json,log}`, `.log/cold_projection_profile_probe.py` (fixed five-second observation window only **after** input; frame events determine success).

The device is left running the newly built **profile arm64 APK**, with user data preserved.

## Unresolved boundaries

Core download-service opening, Home reconciliation and selected-chapter loading still contribute startup latency. This change does not remove that work, and does not replace the previous owner-safety barrier with an unsafe fast path. The supplied trace resumes page **310** and takes the full Home reload path; the device probes resume page **275** and use revision-fast-path adoption. Profile and debug timings also cannot be used as a controlled before/after comparison. Thus the repeated profile results establish functioning early-entry and absence of the long all-scan callback freeze in this tested state, **not** a blanket claim that every cold workload or the exact original page-310/full-reload path is now under 500ms. Debug startup remains slow, and the unchanged synchronous index/materialization stages are not covered by the page-loop budget.

# Cold Reader entry captured bootstrap service ownership

## Input and causal timeline

User-supplied `.log/zic-debug-trace.jsonl`, 143,641 bytes / 289 events. This is a separate cold-start reproduction, not the earlier steady-state navigation trace.

| Relative time | Evidence |
| --- | --- |
| 0.999s | `shelf-comic-tap`, 371-page Venera/EH chapter, `resume-local`; deferred loader is pushed immediately. |
| 1.012s | `reader-prepare-complete`: only 8ms preparation, zero verified mappings, `localAuthorityPrewarmStarted=false`. |
| 1.020s | Reader session created; page 310 mounts at approximately the same time. |
| 1.025s | Five page downloads start while durable download services are not ready. |
| 2.062–2.063s | Durable chapter-download/cache/queue services finish opening; Home changes owner. |
| 3.141s | External plugin host finishes opening. This is a separate capability boundary. |
| 3.387s | Reader cache-read failure: `Bad state: chapter download service is closed`, fallback `origin`. |
| 5.476s | First frame for page 310, `mountToFirstFrameMicros=4455525`. |
| 6.268s | Current page completes an origin/source-loader read of 16,127,124 bytes. |
| 6.604–7.138s | Three promoted-artifact-handoff failures and another cache-read failure against the closed service. |

There are five closed-service `taskFailed` records (two cache reads, three promoted handoffs). This is an ownership defect, not merely debug decoding overhead or a user tapping “too early.” The trace does not independently prove the current page already had a durable local replica; it does prove the Reader used an obsolete backend and its later persistence failed.

## Mechanism and fix

`HomeReaderChapterComposition.prepare` previously loaded/hydrated the chapter, prepared reuse authority and emitted capabilities without joining durable startup/adoption. `_buildImportedChapterScreen` then injected the current `_readerArtifactCache`, optional download store and optional shared transfer runtime into the Pipeline factory. At early cold entry those were bootstrap bindings (or no shared composition). Home later adopted durable services and retired the old owned bootstrap service, but the already-created Pipeline retained that cache backend. Rebinding Home did not rebind an existing Reader.

Reader preparation now has a required composition callback, `ensureDurableServices`. Production wiring joins `HomeServiceHandoff.ensureCoreServices` and `_adoptDurableServices`, and rejects an incomplete adoption rather than falling through to the old owners. The collaborator awaits that callback **before** loading/hydrating, reuse-authority preparation, local prewarm and response projection. The existing deferred route still paints immediately. No wait for unrelated plugin startup, no UI-owned network eligibility gate, and no change to NetLane priority/cancellation policy was added.

`serviceHandoffMs` records this lifetime wait separately from `loadChapterMs`, `hydrateMs`, and overall preparation. No source/cache errors are hidden with extra retries; failed handoff propagates to the deferred route's existing error handling. Composition close continues to join admitted preparation, including a blocked service handoff.

## Regression evidence

`apps/app/test/home_reader_composition_test.dart`:

- A blocked service handoff must prevent chapter load/hydration/authority/binding; after release all observe the adopted owner. Closing while blocked waits for the admitted preparation.
- A failed handoff must surface the original error and must not load a chapter using bootstrap owners.
- Existing local preparation, remote authority refresh and close/admission tests remain.

With the callback wired but not yet awaited, the two new tests fail: preparation observes `load:false` instead of waiting, and failed readiness still produces a prepared chapter (`.log/cold-reader-red.log`). After the await is implemented, all five tests pass (`.log/cold-reader-green.log`).

The device-performance skill now explicitly distinguishes steady-state performance preflight from cold-handoff correctness. Waiting for authoritative Home before every test would mask this user path; the deterministic blocked-handoff regression covers it without a timing-dependent device tap.

## Validation and limits

- Focused preparation/deferred-route/cold-artifact/Home-lifecycle suite: **77 passed**, `.log/cold-reader-focused.log`.
- `LD_PRELOAD=/lib/x86_64-linux-gnu/libsqlite3.so.0 bash tool/check.sh --require-toolchains` exited 0 on the first full run for this change: **27 suites / 1,912 Dart/Flutter tests passed**, 3 existing App skips; repository, documentation, ownership, analysis and platform checks passed. Rust formatting + **22 tests** passed; debug APKs built for all three Android ABIs. Evidence: `.log/cold-reader-final-check.{log,exit}`. `bash tool/check_android_native.sh` also passed. No `dart format` was run.
- Input was preserved as `.log/cold-reader-before-fix.jsonl`; the user's `.log/zic-debug-trace.jsonl` was not overwritten.
- `python3 tool/prepare_reader_device_test.py --mode debug` installed the exact new arm64 APK via `adb install -r` and proved current-process core/Home readiness. A verified Bookshelf/Home selected-state round-trip preceded selection of the latest history card from current accessibility bounds. An initial failed tab tap was discarded; no Reader input relied on it. No data or cache was cleared.
- Device export `.log/zic-debug-trace-2026-09-21T05-08-17.jsonl` confirms the **same 371-page chapter identity** prepares with `serviceHandoffMs=39`, 23 verified authority mappings and `localAuthorityPrewarmStarted=true`; Reader creates, presents, and is retained on exit. There are **zero `taskFailed` events**, four successful local hydrations, and a later successful `stored` / `canonical-bound` handoff. This is a functional smoke after readiness, **not** the early-entry race regression or proof every page avoids origin reads.
- The smoke resumed authoritative page **275**, whereas the supplied trace mounted page **310**. Its observed ~919ms mount-to-first-frame is therefore **not an A/B latency comparison** with the original ~4.456s. The early-entry boundary is verified by the deterministic blocked-handoff tests, not by the device-preflight wait. No post-fix deliberately early device tap or profile/release timing acceptance is claimed.

Original trace timings are observations only, not a release-performance baseline. This fix does not promise zero cold-start storage-open time: that required startup is now awaited by composition, rather than launching a Reader against an owner that is about to close.

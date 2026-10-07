# Home animated-cover card CPU audit (2026-09-20)

## Scope

This audit isolates sustained foreground CPU on Home/Bookshelf artwork cards from Reader, download and source scheduling. The production change does not alter Reader windows, NetLane, Venera invocation concurrency, download/cache ownership, or the original animated artwork stored for details and explicit media presentation.

## Symptom and owner attribution

On the current Profile build, leaving Home idle for more than five seconds repeatedly kept Flutter engine thread `1.io` at roughly 73–81% of one CPU while the main/UI isolate stayed near idle. Running `simpleperf stat` as the app uid against the exact hot TID for two seconds measured about 1465ms task-clock (~0.732 CPU), 3.70G instructions and ~219k page faults. Call-graph sampling was dominated by Flutter image/pixel work: substantial `memmove`/ `munmap` plus texture upload/GPU calls.

UI A/B made the ownership boundary concrete:

- Home: ~77% hot `1.io`.
- Bookshelf: ~73%; it builds the same comic artwork cards.
- Misc tab: 0%.
- App background: 0%.
- Returning to Home: the hot thread immediately returned.

This excludes Reader, SQLite, download scheduling and generic foreground work. The common owner is comic-card artwork presentation.

## Real animated cover

Startup telemetry showed ordinary remote covers at only about 13–67KiB. The single local animated cover had:

- retained static derivative: 49,615 bytes;
- original animated WebP: 5,906,374 bytes.

The real retained original was inspected directly. It is a 1920×1434 infinite WebP animation with 93 frames and a 6199ms cycle (~15fps). All 93 frames cover the full canvas, but 92 carry alpha and require blend/composition against prior state; only the first frame is presentation-independent. Skipping encoded frames or treating the animation as independent images would therefore be semantically wrong.

The pre-fix card flow intentionally showed the retained static derivative first and then permanently switched the mounted card back to the 5.9MiB original. That made a thumbnail card continuously decode and upload the large animation merely because Home/Bookshelf was visible.

## Rejected alternatives

A static-placeholder-only diagnostic immediately removed the hot `1.io` thread, closing causality.

An independent A/B then routed the original through the existing viewport-sized native WebP player. Animation semantics remained intact, but steady work merely moved from Flutter `1.io` to native decode/texture scheduling: roughly 40–50% CPU-equivalent. Capping native output to the card's existing 512px raster budget improved this only partially because almost all encoded frames form a dependent blend chain. No native-player or decoder experiment was kept.

Generating a new low-resolution animated derivative was also rejected for this fix: the repository currently owns a first-frame static thumbnail capability, not an animated WebP encoder/cache format. Introducing one would create a new long-lived transformation/cache responsibility when the card presentation requirement is already satisfied by an existing retained derivative.

## Production boundary

Home/Bookshelf card composition now resolves local animated covers through the existing retained `cover-placeholder` derivative and exposes that source as the card's final presentation source. The card no longer simultaneously loads a placeholder and the original animated final.

The original `cover` artifact is still materialized and retained with its source-revision-bound identity. Details uses its independent cover loader and continues to load/play the original animation. The fix therefore separates thumbnail presentation from artwork/content authority instead of changing the underlying cover identity.

## Device validation

Fresh main Profile after rebuilding/installing the actual production diff:

- Home authoritative startup: ~0.97s.
- Three Home idle thread samples after settling: every app thread 0%; the old 73–81% `1.io` runaway is absent.
- Bookshelf idle: every app thread 0%.
- Fresh trace `zic-debug-trace-2026-09-20T08-34-37.jsonl`: local card has exactly one `homeCoverSourceReady`, 49,615 bytes, `presentationStage=final`; no 5,906,374-byte card final is loaded. Request→first-frame is about 126ms.
- Opening the same local comic's details is independently verified by UI semantics; the original animation again drives `1.io` to ~80.7%, proving original animated content authority is intact. Returning Home drops the related threads back to 0%.
- Reader smoke after tapping the local card, with no page swipe/tap inside Reader: exported trace contains `pipeline-reader-1`, page19 `pageHostMounted`→`firstFrameReady` in about 223ms.

That Reader trace also contains one later `taskFailed` for page20 as speculative `next` priority820 after repeated transport-open stall. Current page19 had already presented successfully. This is a separate loading signal and must not be attributed to or hidden by the cover-card change.

## Validation

- `apps/app/test/library_ui_test.dart`: 26/26 pass.
- repository structure: pass.
- Dart structure: pass.
- `git diff --check`: pass.

The production change is intentionally confined to Home card-source composition and the existing local-cover helper.

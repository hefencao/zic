# Interior Reader entry retains its absolute center

Status: Accepted

## Context

The ordinary minified Release presents cached JM chapter6 content at1s/6s,
with11 artifact reads, no download and no failure. Without a gesture, its
history entry changes from index2 to3 about44ms after pageCurrent2. The later
short-page geometry puts the viewport center on the next page.

Two valid failing-first widget cases reproduce index2 becoming3, both on the
first mount and on Controller replacement. Entry has already acknowledged its
absolute command against provisional viewport-sized pages. A later source
ratio uses the ordinary top anchor, which cannot retain that requested center.
This is a navigation geometry defect, not evidence of invalid cached bytes,
URIs, trust or repeated download.

## Decision

Reuse the existing retained absolute page anchor for interior entry and slider
selection. Bind its index to the original navigation revision so deferred
entry positioning keeps the same anchor and a newer command retires it.
Entry acknowledgment ends its command phase but does not prove dimensions
have converged. Late ratios use the existing atomic centered layout correction.

Actual content motion, a new page/viewport command, direction change or
Controller replacement retains the existing retirement boundary. First/last
entry keeps its explicit edge alignment. Ordinary idle/content-scroll keeps
top-pixel anchoring after motion takes over, and the real tail keeps its
ScrollMetrics policy. No timer, worker, executor, media-ready gate, resource
owner or scheduler is added; Pipeline, NetLane and all windows are unchanged.

## Verification and limits

Both failing-first cases pass after the one-file production change and verify
two separate late short-page ratio updates, zero idle velocity and physical
drag returning to ordinary top-pixel anchoring. All99 Reader tests pass.
The full gate passes2280 Dart/Flutter tests,27 suites/analyzers and22 Rust
tests;108 Android tests and all-three-ABI Profile/minified Release packages
pass. Three actual force-stop/relaunch cached JM entries keep the real saved
index3, with11 cache reads each and no download/failure. The old Release had
already persisted that index after its observed drift; device acceptance does
not rewrite user progress to manufacture an index2 history. Six slider/edge
steps and three independently preserved-history boundary entries pass with
content at1s/6s. Five same-process exports, deduplicated rather than summed,
contain226 cache reads and no download/failure. All120 complete chapter
payloads remain exact; exported changes match only actual reading.
Evidence and final status are recorded in
`docs/audits/vertical-history-entry-late-dimensions-2026-10-04.json`.
The original chapter19/20 intermittent loading cause and final display
performance remain separate open criteria.

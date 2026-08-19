# ADR 0293: Fixed-position hidden static upload boundary

Status: FALSIFIED by dev.314 device evidence; production behavior rolled back in dev.316.

## Context

The dev.313 10:26 trace is from the low-performance device only. The native Choreographer summary is mostly 14-18ms (2825/2968 intervals), but the user can reproduce visible jank at the same content positions. `scrollCadenceOutlier` is correspondingly non-uniform: currentIndex 20=42, 12=19, 22=15, 23=13 out of 148. Global frame-rate scheduling may amplify a missed frame, but cannot by itself explain deterministic content-position hotspots.

The concrete ZIC path is stronger: decoder classification calls `PipelineController.classifyPage()`, which force-replans from the last observation. Before dev.314, `localPresentationReady=true` exempted a hidden static page from active-scroll upload deferral. At 40.658911s page11 became authoritative local static, a hidden `next2` upload was added, and the 712x2336 Android texture later spent 16.163ms in platform blit, ending at 40.677365s immediately before the 40.679514s 32.845ms cadence outlier. Correlated platform uploads in the trace are dominated by `next2` (16/19).

The canonical library reference is `vibevenera-master.zip`, SHA-256 `fbd2bdfa8980f928c59d4af7a9cc162abbe9d283f9306c358b9a3cec4f5c38a7`. Its ordinary static Reader path uses `ReaderImageProvider`/`ComicImage`; its streaming Pipeline also coalesces scroll-time page commits with a resettable 180ms timer. That comparison motivates removing ZIC's off-screen texture work first, without importing VibeVenera's whole architecture or adding a second intervention.

## Decision

During vertical `dragging`, `scrolling`, or `settling`:

- hidden static pages inside the existing stable decode window keep DecodeDemand;
- no hidden speculative UploadDemand may be created, even when decoder classification is authoritative static and the body is direct-local or `residentBodyBacked`;
- current, transition, and actually visible static pages remain eligible to upload;
- idle restores bounded local/static pre-presentation;
- encoded 7/3, decode previous1/next2, NetLane, geometry, ScrollPosition, ScrollPhysics, renderer and Android frame policy remain unchanged.

The dev.308 reverse-geometry decision remains accepted. Only its active-hidden-local-static upload exception is superseded.

## Why not the 180ms control debounce yet

`mediaClassified()` can force-replan independently of `PipelineReaderSession.enqueueObservation`, so a control debounce alone would not stop this exact hidden upload. Adding both changes would also destroy causal attribution. The debounce remains a separate follow-up only if dev.314 fails.

## Falsification

Repeat the same scroll path on device. The hypothesis gains support if fixed-index hotspots and active role=`next`/`next2` first-time texture blits collapse while visible/current presentation remains continuous. If the same positions still produce comparable gaps after hidden active uploads disappear, reject this route and test the separate control-commit hypothesis. Background platform cadence misses are not required to disappear for this component to be valid.

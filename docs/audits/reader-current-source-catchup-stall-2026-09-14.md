# Reader current source catch-up stall — 2026-09-14

## Observed stall

The fresh profile trace `.log/zic-debug-trace-2026-09-14T09-41-29.jsonl` contains an Animated WebP page whose existing mutable prefix was 1,068,720 bytes. The provider request carried `Range: bytes=1003184-`, and the physical transfer was already admitted as the priority-820 immediate-next task before the page became current. The same request returned HTTP 200 rather than a ranged response.

This rules out the tempting explanation that the transfer simply started too late. From the priority-820 `downloadStarted` event to the HTTP 200 response/open completion was about 2.01 s. The response then had to replay and continuity-check the already committed prefix before any bytes beyond 1,068,720 could become authoritative. The old-prefix catch-up took about another 5.48 s; the same response continued growing at roughly 0.17–0.20 MiB/s after crossing that boundary, so the catch-up duration is consistent with actual response throughput rather than an internal decoder/writer/NetLane lock. There was no speculative encoded-budget release/acquire cycle for this physical task across the catch-up interval.

The continuity check cannot safely publish the tail before the duplicate prefix has matched: when a Range request is ignored and becomes HTTP 200, bytes after the old boundary are only a valid continuation if the replayed prefix proves that the response is the same body. The fix therefore does not pretend HTTP 200 is HTTP 206, remove the overlap proof, or raise the Reader transfer rank.

## Visible freeze cause

The existing prefix had already decoded frames 0–20, each with a 50 ms duration, before source growth stalled. That is 21 real frames / 1.05 s of playable animation. Native decoding itself was not the long pole: the later frame-21 decode took about 42 ms, while its recorded source wait was about 6.30 s.

`DecodeSession` nevertheless used the legacy 30-frame partial-prefix threshold as the only loop qualification. Once frame 20 was consumed, the holder became empty at 21 frames and playback waited for source growth even though a full second of real animation was already available. The trace later entered the existing partial-prefix loop only after the growing source had yielded more than 30 frames.

The loop qualification is now frame-rate aware while preserving the old fallback. An unsealed, decoder-independent animated prefix may cycle only after at least two real decoded frames and either:

- it reaches the existing `partialLoopMinFrames` threshold (30 by default), or
- accumulated decoded frame duration reaches one second.

This is a playback-only fact. It does not modify DownloadDemand rank, the 3/7 encoded window, NetLane, transport admission, resume validators, cache/partial authority, or decoder-driven local source growth. Trace payloads now include the decoded prefix duration so future stalls can distinguish “not enough playable time” from “network still catching up”.

## Validation

`packages/sessions/test/decode_session_test.dart` passes 24/24, including a trace-shaped 21 × 50 ms positive case and a 19 × 50 ms (950 ms) negative case. The existing 30-frame case and decoder-driven-growth no-loop case remain covered. `packages/sessions/test/live_coordinator_test.dart` passes 28/28, including unsupported-Range admission and the last-buffered-frame partial-loop re-entry path.

A newly rebuilt Profile APK with release-native media was then installed with `adb install -r` without clearing user data. Fresh trace `.log/zic-debug-trace-2026-09-14T11-07-29.jsonl` reaches the new production qualification directly: the current decode session is unsealed at `sourceLength=1,048,576`, reports 21 known frames at 50 ms each, and its `decode-prefix` retry records `decodedPrefixFrames=21` plus `decodedPrefixDurationMicros=1,050,000`. This proves the duration evidence is present on the real production path rather than only in a unit-test fixture.

That device run did not need to loop: source growth reached 2 MiB before the buffered prefix was exhausted, and frame 21 waited only about 8.6 ms for source. Accordingly `partial prefix loops: 0` in that trace is not a negative result. A later coordinate swipe was deliberately not interpreted as a page transition because the navigation analyzer reported no committed Reader gesture. The exact slow-origin visual case remains observationally untriggered on the rebuilt APK, while the causal fix, production qualification and no-regression paths are all established. Future device validation should wait for another naturally slow ignored-Range catch-up rather than manufacturing different Reader/window behavior to force the condition.

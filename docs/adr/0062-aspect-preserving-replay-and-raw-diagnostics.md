# ADR 0062: Aspect-preserving decode bounds, demand replay and raw diagnostics

Status: Accepted in `0.31.0-dev.78`; export non-coalescing detail superseded by ADR 0081 in dev.97.

Supplements ADR 0061. It does not reopen the atomic media-runtime ownership decision or change Pipeline policy windows.

## Context

The dev.77 atomic migration correctly moved WebP cursor, decode, upload and texture ownership into Pipeline, but four integration defects remained:

1. `DecodeId.physicalWidth/physicalHeight` were passed into the native cursor as if they were an exact output size. The decoder scaled X and Y independently, so pages whose source aspect differed from the viewport were distorted.
2. A static/finite page could leave decode demand after its only frame had been consumed into upload output. `DecodeSession` retained the now-ended cursor while its holder was empty. Re-entering the window therefore observed EOF instead of reproducing a first frame.
3. Details Presentation loaded every unknown chapter body solely to fill page-count labels. Those calls competed with the chapter the user had actually selected and could delay Reader navigation.
4. `DebugTraceLog.events` was intentionally a small, coalesced UI projection, but copy/export reused it. Diagnostic export therefore omitted raw events and file-save failures were unreported.

The fixes must preserve the +7/-3 download window, +2/-1 decode window, current/transition upload set and 5/3/2 lanes. They must not retain all frames/textures, automatically loop every EOF, move chapter-body loading into App metadata presentation, or make trace storage unbounded.

## Decision

1. `DecodeId.physicalWidth` and `physicalHeight` are maximum raster bounds, not an exact output rectangle. Native decoders inspect the source canvas and choose the largest no-upscale size that fits inside both bounds while preserving source aspect ratio.
2. Decoded frames and uploaded outputs report their actual fitted width and height. Android texture allocation uses those actual frame dimensions. `UploadSession` validates output dimensions against the claimed source frame and verifies they remain positive and within the DecodeId bounds.
3. A stable `DecodeId` must produce one stable output size. If a native decoder changes dimensions within that identity, the uploader retires the slot and fails rather than stretching or silently reusing an incompatible texture.
4. `DecodeSession.detach` marks a possible replay boundary. On the next WebP demand, it recreates the cursor only when the decoded holder is empty. A retained frame remains reusable. Ordinary EOF does not rewind; finite animations and static images do not become unconditional loops.
5. Catalog/details Presentation does not call `loadChapter` to discover page-count metadata. Unknown counts remain `页数待加载` until the target chapter is opened/downloaded or authoritative catalog metadata arrives.
6. Read-state persistence is removed from the synchronous navigation critical path. The details projection updates optimistically; the central App navigation owner submits the durable write without delaying route push.
7. `DebugTraceLog` owns two bounded projections: a small coalesced UI ring and a larger diagnostic export ring. dev.78 initially kept that export ring non-coalesced; ADR 0081 now permits fixed-window summaries for high-frequency events while preserving errors and authoritative lifecycle edges. Session filtering, copy and file export use the diagnostic ring.
8. Debug file export is an injectable capability. The default App implementation uses the platform save location; cancellation is silent, success reports the raw count, and failures are surfaced instead of disappearing from an unawaited callback.
9. The compile boundary is explicit: `pipeline_media_runtime.dart` imports domain-owned `RendererKind`; `UploadRegistry` asks `UploadSession.playbackRunning` and does not depend on the session-internal `PlaybackState` enum.

## Consequences

- Wide, tall and small WebP pages keep their geometry and are bounded by the decode budget without forced upscaling.
- Re-entering a retired static/finite WebP page can reproduce a first frame without keeping every decoded frame or texture alive for the chapter lifetime.
- Chapter clicks no longer wait behind App-generated page-count body preloads. The selected chapter may still require its own source manifest/network operation, which remains authoritative and is not hidden by fake page data.
- Debug UI stays cheap while copied/exported JSONL preserves up to the diagnostic-ring limit, reports dropped buckets, and exposes summary counts/ranges under ADR 0081.
- ADR 0061 remains authoritative for media ownership. Presentation still receives only opaque Pipeline output and may not create a competing cursor, uploader or texture lifecycle.

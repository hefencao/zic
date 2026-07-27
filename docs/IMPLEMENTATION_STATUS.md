# Implementation Status

## 0.8.0-dev.8 — watermark accounting and playback progression

### Reported failure fixed

The same decode identity could be woken once when the WebP source became ready
and again when the download completed. Uploading consumed the decoded holder
frame, so the second decode refill treated the watermark as empty and produced a
second output.

The resource watermark now counts both:

- decoded frames retained in `FrameHolder`; and
- the renderer-owned output currently retained by `UploadSession`.

A ready output therefore satisfies a watermark of one. Source/download wake-ups
can no longer advance the animation by themselves.

### Lane follow-up semantics

Added `TaskLane.follow()`. It coalesces one successor per key without cancelling
the active task. Demand changes still use `replace()`, while source/frame-ready
wake-ups use `follow()`. This prevents duplicate upload allocation while also
avoiding a lost wake-up when readiness changes during active work.

### Explicit playback progression

Added:

- `UploadSession.advance()` and `UploadRegistry.advance()`;
- `LiveCoordinator.advanceFrame()` and `advanceDueFrame()`;
- `PlaybackTimer` with running/frozen/idle states;
- freeze/resume APIs; and
- timer reset after actual `OutputFrame.present()` completes.

The current renderer output remains part of the prepared depth until an explicit
advance retires it. Advancing wakes upload/decode to prepare the next frame.

### Tests added or extended

- The reported coordinator test continues to require exactly one initial output.
- Explicit advance produces the second output and frame index.
- Ready output contributes to decode watermark without calling the cursor.
- Lane follow-up does not cancel active work and coalesces to the latest task.
- Playback duration begins after present, fires once, and preserves remaining
  duration across freeze/resume.

### Next iteration

1. Implement native cursor/frame ABI and `FrameRef` bridge handles.
2. Add decoded/output byte budgets with a reserved current-page allocation.
3. Add viewport overlap/dominant freeze integration.
4. Add Android `SurfaceProducer` texture registry and serial blit worker.

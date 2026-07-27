# Implementation Status

## 0.7.0-dev.7 — restore I/O fix and upload/present ownership

### Reported failures fixed

- `media/src/frame.dart` now imports the local `EncodedSource` contract.
- `Artifact.readPrefix()` now awaits `RandomAccessFile.read()` before its
  `finally` block closes the handle. Returning the pending future directly was
  the common cause of the restore/resume `An async operation is currently
  pending` failures.
- Added a regression test that reads a prefix, closes the artifact, and then
  reopens the file immediately.
- Repository validation now rejects both regressions.

### Upload and present boundary

- Added pure Dart `OutputFrame` and `FrameUploader` contracts. Output frames can
  represent Flutter images or platform textures without exposing native frame
  pointers to application code.
- Added `UploadSession` and `UploadRegistry`.
- Upload work takes an upload claim on the decoded frame, releases the claim in
  all success/failure/cancellation paths, then consumes the source frame only
  after a renderer-owned output frame exists.
- Output frames have independent present claims. Detach, replacement, reset,
  and dispose retire an output immediately only when no present claim is
  active; otherwise disposal is deferred until the final claim is released.
- Stale-epoch or wrong-index upload results are disposed and rejected.
- `LiveCoordinator` can now use either the existing upload callback or a real
  `UploadRegistry`, and successful decode work wakes matching upload demand.

### Telemetry

Added:

- `uploadState`
- `frameUploaded`
- `framePresented`

### Tests added

- Prefix-read file-handle lifecycle regression.
- Upload consumes the decoded source frame only after successful upload.
- Present claim keeps an output alive across detach.
- Stale uploaded output is disposed and cannot become current.

### Next iteration

1. Implement native cursor/frame ABI and `FrameRef` bridge handles.
2. Add Android `SurfaceProducer` texture registry and serial blit worker.
3. Add decoded/output memory budgets with a current-page reserve.
4. Add playback clock, present freeze/resume, and frame-duration reset.

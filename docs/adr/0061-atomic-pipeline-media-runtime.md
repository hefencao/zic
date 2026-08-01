# ADR 0061: Atomic Pipeline media runtime and opaque page output

Status: Accepted in `0.31.0-dev.77`.

Supersedes the Reader streaming/decode ownership part of ADR 0044 and closes the boundary debt recorded by ADR 0057 and ADR 0060.

## Context

`pipeline_runtime` already owned Reader demand, download sessions, artifacts and lane scheduling, but `PipelinePageStream` still exposed the mutable `EncodedSource`. `local_media_ui.NativeWebpPlayer` used that source to create its own native cursor and Android texture presenter. As a result, Pipeline emitted decode/upload demands while the page Widget performed the actual decode/upload lifecycle. The same page therefore had two semantic execution chains, platform objects were closed by Widget lifetime, and an API migration could leave source/cursor/uploader/projector capabilities only partially updated.

The migration must preserve the established +7/-3 download window, +2/-1 decode window, current/transition upload set and 5/3/2 lane capacities. It must not move `bridge` or `texture_bridge` dependencies into a core package, expose texture IDs/native handles to Presentation, or temporarily fall back to a second complete-byte native decode path.

## Decision

1. App composition injects one `PipelineMediaRuntimeFactory`. Each `PipelineReaderSession` creates exactly one owned `PipelineMediaRuntime` containing the matching `SourceFactory`, `CursorFactory`, `FrameUploader`, `PipelineOutputProjector` and `RendererKind`.
2. `pipeline_runtime` depends only on those abstractions. The native implementation lives in the separate `pipeline_native` composition package, which may depend on `bridge` and `texture_bridge`.
3. `PipelineReaderSession` creates and wires `SourcePool`, `DecodeRegistry`, `UploadRegistry`, `FrameBudgeter` and `LiveCoordinator` from the same runtime. The injected renderer must match the Reader decode target.
4. `PipelinePageStream` remains a read-only transfer/content projection and no longer exposes `EncodedSource` or any mutable session/platform object.
5. Presentation consumes `PipelinePageOutputStream`. It receives immutable state plus an opaque `PipelinePageSurface`; no `DecodeId`, texture ID, native frame handle, upload claim, cursor or artifact store crosses the boundary.
6. Output claims are owned by Pipeline. A previous surface remains claimed while a replacement target/frame is preparing, then is released after the replacement has been presented, projected and given one Flutter frame to replace the old surface.
7. Android textures are allocated per stable `DecodeId`, reused across animation frames, retired when that identity leaves upload ownership, and released only after the final claimed `OutputFrame` owner is gone. Session close drains all retired leases.
8. Pause and playback-speed commands enter `PipelineReaderSession` as one registry-owned playback configuration. Upload sessions retain independent user-pause and viewport-freeze reasons, including before their first frame timer exists; the Reader ticker runs only while at least one current upload timer is running, and Presentation does not advance Pipeline-owned native cursors.
9. `DecodeSession` only creates the current native cursor for `SourceKind.webp`. Non-WebP complete-artifact Presentation remains unchanged in this migration and is not routed into a failing native cursor or used to reduce demand windows.
10. Close order is output claims, coordinator work, artifact handoff/read observers, upload/decode registries, media runtime, downloads/source pool/transports and workspace. Externally injected factories are not closed; the session-created runtime is.

## Consequences

- Reader WebP source, cursor, decoded frame, upload frame, Android texture and animation advance now have one authoritative Pipeline lifecycle.
- `local_media_ui` can render the opaque surface and page-local loading/error state, but cannot select a renderer or touch mutable media/session/platform objects.
- Native platform dependencies remain above `pipeline_runtime` and are atomically supplied by App composition.
- A texture may outlive removal from the uploader map while an old surface claim is still visible; replacement claims are released after the next Flutter frame and deterministically complete retirement without use-after-release.
- Static image/GIF complete-artifact rendering is explicitly outside this WebP streaming migration. Any later unification requires its own capability/format design and must not restore a parallel Reader WebP decoder.

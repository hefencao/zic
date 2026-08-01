# Next chat handoff

## Sole baseline

Use only:

`zic_v0.31.0-dev.77_atomic-pipeline-media-runtime.zip`

Do not merge dev.65–76 candidates, overlays or remembered source trees. Mihon and VibeVenera references remain read-only.

## Completed in dev.77

- Replaced source-only composition with one App-injected `PipelineMediaRuntimeFactory`; each Reader session owns one atomically matched source/cursor/uploader/output/renderer runtime.
- Added `pipeline_native`; `pipeline_runtime` has no bridge/texture dependency.
- Wired production DecodeRegistry/UploadRegistry into LiveCoordinator without changing +7/-3, +2/-1, current/transition or 5/3/2.
- Removed `PipelinePageStream.source` and all Reader Presentation streaming-cursor/texture use.
- Added read-only `PipelinePageOutputStream` and opaque `PipelinePageSurface`; no `DecodeId`, texture ID/native handle/output claim crosses into Presentation.
- Routed Reader pause/speed and animation due-frame advance through Pipeline ownership.
- Added per-DecodeId, frame-claim-safe Android texture retirement and runtime close drain.
- Migrated the App media Pipeline demo and tests in the same API closure; no compatibility parameter remains.
- Added ADR 0061, dev.77 audit/static gate and owner tests. Built the user-supplied libwebp 1.6.0 source and passed host incremental/loop checks.

## Next validation

1. Run `flutter analyze`, all package tests including `pipeline_native`, App tests and Android debug/release or kernel snapshot.
2. On Android, verify current and transition WebP surfaces appear without reverting to complete-byte decode, and target replacement keeps the old surface until the new one is ready.
3. Exercise animated WebP pause, resume and 0.25–4x speed; correlate due-frame, upload and first-frame telemetry.
4. Enter/exit long chapters while watching texture/GPU memory; evicted DecodeIds must retire after the final page-output claim, not accumulate until chapter exit.
5. Repeat immediate Reader exit during create/present and confirm runtime close drains pending texture leases without late callbacks or post-exit receiving.
6. Design non-WebP complete-artifact output unification separately; do not restore `PipelinePageStream.source`, direct Reader cursor creation or a second WebP decoder.

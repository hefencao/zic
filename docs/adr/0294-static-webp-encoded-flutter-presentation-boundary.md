# ADR 0294: Authoritative static WebP uses encoded Flutter presentation

## Status
Accepted for dev.315 device falsification. dev.314 fixed-position hidden-static upload timing is **FALSIFIED as the root**: it removed active hidden `next2` pre-upload, but the 11:45 low-performance-device trace still contains 173 `scrollCadenceOutlier` events and moved first physical copies onto visible `transition` seams.

## Evidence
The dev.314 trace contains 14 `mediaClassified` events and 14/14 are authoritative static (`animated=false`, `frameCount=1`, `complete=true`). There are 13 physical `framePipelineTiming` copies with `platformBlitMicros>0`; every one reports `surfaceReconfigureCount=1`. Visible transition copies include 16.588ms, 13.594ms, 12.178ms, 11.613ms and 10.837ms. Thus delaying speculative upload changes *when* the first SurfaceProducer copy happens, but does not remove the per-page RGBA copy from the scrolling seam.

The repository comparison uses the user-supplied Library archive `vibevenera-master.zip`. Its ordinary static reader path uses `ReaderImageProvider` / `ComicImage` with compressed bytes consumed by Flutter's image decoder; its SurfaceProducer/native-blit path is reserved for streaming animation. This is a presentation-topology difference, not evidence that Flutter itself is the root cause.

## Decision
For production Android Reader pages whose transport is already observed as WebP, do not create an Android-texture `UploadDemand` while animation truth is unresolved. Native decode remains the authoritative animation classifier. If classification resolves `animated=true`, the existing native SurfaceProducer path is enabled. If it resolves `animated=false`, presentation loads the Pipeline-owned encoded artifact bytes and feeds those compressed bytes to Flutter `MemoryImage` / ImageProvider. Static WebP therefore never performs RGBA -> SurfaceProducer first-copy work.

This is deliberately different from dev.311. dev.311 decoded natively to RGBA and then called Flutter `decodeImageFromPixels`, adding a large RGBA conversion/output-preparation cost. dev.315 lets Flutter decode the original compressed WebP bytes for static presentation while retaining native decode only as classification/prewarm evidence.

## Invariants
Encoded 7/3, decode previous1/next2, NetLane, Reader geometry, ScrollPhysics, Choreographer observation, and animated-WebP native texture playback remain unchanged. The encoded-byte route consumes existing Pipeline artifact authority; it does not add a Reader byte cache or transport owner.

## Falsification
On the next same-chapter device run, authoritative static pages must emit `staticEncodedPresentation` with route `pipeline-compressed-bytes-flutter-codec`, and must not later produce static Android texture platform blits. If fixed seam jank remains after static SurfaceProducer first-copy work is mechanically absent, this topology is falsified and the next single variable is VibeVenera's scroll-time delayed Pipeline/current commit (180ms), not another texture-window timing tweak.

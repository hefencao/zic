# dev.315 static WebP encoded-presentation audit

Source trace: `zic-debug-trace-2026-08-19T11-45-04.jsonl`, low-performance device only. No inference from the earlier high-performance-device run is used here.

## dev.314 falsification
- 4202 parsed events.
- 173 `scrollCadenceOutlier`; median gap about 27.289ms, max 52.196ms.
- 14 `mediaClassified`; 14/14 are `animated=false`, `frameCount=1`, `complete=true`.
- 74 `framePipelineTiming`; 13 have positive `platformBlitMicros` and all 13 have `surfaceReconfigureCount=1`.
- Transition first-copy examples: 16.588ms, 13.594ms, 12.178ms, 11.613ms, 10.837ms.
- dev.314 successfully suppresses active hidden authoritative-static warming, but the same physical work is then paid when a decoded page becomes `transition`. Therefore the hidden-next2 timing hypothesis is FALSIFIED as the root; it shifted work rather than deleting it.

## Source-level cause class
`TextureBridgePlugin` already dispatches native blit on its dedicated serial blit executor, so “move the copy off Android main thread” is not the missing fix. The native Android path still locks/configures an ANativeWindow and copies the complete premultiplied RGBA frame into a SurfaceProducer buffer before `scheduleFrame`. The observed first copies are 5-16.588ms and systematically reconfigure the surface on first use.

The user-supplied `vibevenera-master.zip` is the comparison source. Ordinary static pages use compressed-byte `ReaderImageProvider` / Flutter codec presentation, while its native SurfaceProducer path is for streaming animation. This makes “static page uses external texture at all” a higher-value variable than “which page role starts the same copy”.

## dev.315 intervention
1. Transport sniff already records runtime WebP cost evidence before authoritative animation classification.
2. With Android texture renderer, a runtime-observed WebP whose animation state is not yet `true` receives decode demand but no texture upload demand. This closes the decode-complete/classification-microtask race.
3. Decoder `AnimationInfo` is projected through `PipelinePageStreamSnapshot.animated`.
4. `animated=false` + WebP activates encoded static presentation in `LocalImagePlayer`.
5. The existing Pipeline token/artifact bytes loader supplies the original compressed bytes; `MemoryImage(bytes)` is the presentation source.
6. `staticEncodedPresentation` traces format, encoded byte count and `route=pipeline-compressed-bytes-flutter-codec`.
7. `animated=true` re-enables the existing native texture upload path.

## Negative controls
No 180ms control debounce, high-refresh vote, ARR behavior, touch resampling, forced frame, ScrollPhysics change, geometry change, window shrink, decode-window widening, NetLane change or dev.311 `decodeImageFromPixels` route is introduced.

## Next proof
Repeat the same chapter/positions. First verify static pages emit `staticEncodedPresentation` and that after runtime WebP observation there are zero static SurfaceProducer platform blits. Then compare seam-local `scrollCadenceOutlier`. If the fixed-position symptom is unchanged with the copy absent, close this route and test only the VibeVenera-style 180ms scroll-time control commit delay.

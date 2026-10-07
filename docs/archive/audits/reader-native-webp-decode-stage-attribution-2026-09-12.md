# Reader Animated WebP native decode stage attribution — 2026-09-12

## Scope

This audit closes the current native Animated WebP performance attribution branch on top of:

- `2c38c317` — foreground measured-throughput adaptive decode raster;
- `f88ac676` — versioned `dev135-abi6-lib00121500` native decode diagnostics.

The purpose is not to define a new scheduling policy. It records which part of the decode path still costs time after the already accepted fallback and which explored alternatives have been mechanically rejected.

## Device facts

Device: M2007J1SC, power-save reproduction with the same process returning to `/top-app` while actual native FFI tasks can independently retain a restricted CPU mask.

Normal foreground sample (`zic-debug-trace-2026-09-11T21-54-58.jsonl`):

- actual native masks were wide: `0x3f / 0x5f / 0x6f / 0x7f`;
- 1072×1608 dominant animation fragment decode median was about 34 ms;
- total native decode remained about 40–42 ms;
- dev135 successfully projected native prepare/canvas/fragment/composite/copy, OS TID, CPU start/end/allowed mask and bounded frame-structure facts into Trace.

Restricted sample (`zic-debug-trace-2026-09-11T22-05-18.jsonl`): actual native FFI reached `nativeCpuAllowedMask=0x0f` and the production governor changed full raster to severe.

| Raster | Native total median | Fragment median | Composite median | Frame copy median |
| --- | ---: | ---: | ---: | ---: |
| 1072×1608 | 171.00 ms | 140.75 ms | 20.20 ms | 6.65 ms |
| 544×816 | 82.97 ms | 74.34 ms | 5.69 ms | 0.52 ms |

At severe raster, fragment decode therefore owns roughly 90% of the remaining native time. Even eliminating Rust composite and frame-copy completely cannot restore the 50 ms source cadence.

The same restricted trace also showed long animation dependency runs. One current snapshot had 207 known frames, 199 full-canvas frames, only 1 presentation-independent frame and a maximum dependent run of 206. Another snapshot reached 301 / 290 / 1 / 300 respectively. Full-canvas coverage therefore does not imply safe frame skipping: most frames still carry alpha/blend dependency on the previous canvas.

## Rejected or exhausted directions

The following directions have device or source-level evidence against reopening them without materially new evidence:

- **Logical decode-worker rotation:** different Dart workers can execute on the same OS TID; repeated background/resume reproduced `0x0f` on both workers.
- **Worker retirement/recreation:** a fresh worker/TID could be fast for one frame and then be restricted again by MIUI. The uncommitted retirement/prewarm lifecycle experiment was removed completely.
- **libwebp `use_threads=1`:** nested threading made this workload substantially slower, including when the outer FFI thread had a wide CPU mask.
- **Parallel ANMF fragment pair:** under real `0x0f`, ordinary half-raster decode was about 82 ms/frame while pair amortization was about 106.6 ms/frame.
- **Missing SIMD/NEON:** the arm64 source build has `WEBP_ENABLE_SIMD=ON`, `WEBP_HAVE_NEON`, compiles the NEON decode/lossless/rescaler/YUV paths, and the arm64 runtime dispatcher returns true for `kNEON` and installs the NEON DSP tables.
- **Manual low-quality decode flags:** libwebp already disables fancy upsampling whenever scaling is active and automatically bypasses filtering when the scaled dimensions are below 3/4 of source dimensions. Moderate/severe therefore already receive those fast paths.
- **1:1 rescaler bypass:** a temporary device A/B changed full-raster fragment median only from about 33.97 ms to 33.87 ms. The experiment was reverted and the device was restored to the production dev135 APK.
- **Dependency-blind frame skipping:** current frame-structure evidence shows only one independent frame across dependency runs above 200–300 frames; skipping decode would corrupt later blended canvas state.

## Production conclusion

The remaining restricted-state bottleneck is primarily the single-frame libwebp fragment decode running on CPU resources that the OEM has restricted, not Reader predecode, network/cache reuse, Flutter page construction, texture creation or a missing SIMD build option.

Production should therefore retain the existing measured-throughput fallback rather than accumulating more decoder ownership or scheduler policy:

- normal compute keeps full raster;
- current Animated WebP that repeatedly misses its own cadence may degrade raster through the existing governor;
- the governor must continue to use measured native decode time, not power-save state, CPU ids or affinity as policy authority;
- background Reader media remains paused by lifecycle ownership rather than hidden decode-quality changes;
- no affinity/performance-lock/worker-recreation workaround should be reintroduced.

The severe 1/2 raster still does not make a 50 ms source frame fully real-time on the reproduced `0x0f` state. That limitation is explicit rather than hidden: the measured residual is about 74 ms of fragment decode before the remaining ~8 ms of native canvas/output work.

## Reopen criteria

Native decoder optimization should be reopened only if at least one of these changes:

1. a different decoder backend can be demonstrated on the same real animation and restricted device state;
2. new evidence shows a substantial class of truly independent/key frames that can be skipped or cached without breaking canvas semantics;
3. a generic optimization reduces the fragment stage itself, not merely the <10% severe-raster composite/copy tail;
4. a fresh manual-use Trace shows a different dominant stage than the dev135 attribution above.

Synthetic ADB swipe `mountToFirstFrame` measurements are not sufficient evidence for a media-predecode regression. Existing traces already show neighboring pages decoding several seconds before mount and transition frame0 becoming resident in roughly 68–73 ms; PageView gesture/settle time must be separated from media readiness.

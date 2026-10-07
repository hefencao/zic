# Static vertical Reader: active diagnostic wakeups

## 2026-09-24 follow-up

A later external review attributed static-vertical power to five additional mechanisms. Re-reading the current production path changed that classification:

- idle static warming is intentional. The policy restores the existing 3/7 one-frame static intent window after active presentation motion so necessary work is shifted away from scrolling. Although the plan contains multiple intents, `StagedDecodeRefillPolicy` elects one actual refill at a time before decode work; removing idle warm would be a preload regression, not a power fix.
- the reported per-image geometry cascade is partly stale. `reader_runtime` already coalesces pending source-canvas ratios into one post-frame publication, and decoded presentation raster dimensions cannot overwrite an established source-canvas basis. No new debounce or Reader-local geometry bypass is accepted without a fresh trace proving repeated source-canvas updates remain material.
- the initial six-screen cache pass, nominal `current±7` keepAlive, and bounded three-pages-per-frame idle recenter are composition behavior, not decoded/upload/texture residency owners. They remain unchanged pending device evidence.
- one genuine diagnostic residue remained: the Dart `verticalSceneMotion` probe still recursively sampled `RenderBox.localToGlobal` during active vertical frames even when the Android cadence diagnostics were disabled. It now uses the same `ZIC_READER_FRAME_CADENCE_DIAGNOSTICS` opt-in. This changes diagnostics only; warm windows, decode/upload lanes, geometry, keepAlive and presentation policy are unchanged.

## Scope and status

The user reports elevated power consumption, especially while reading static images vertically. This change removes one confirmed source of unnecessary activity; it does **not** yet establish that all elevated power consumption is explained or fixed. Final repository verification and the targeted static-vertical device run passed. Device evidence shows reduced Android-main idle CPU; offline trace analysis completed after a same-protocol recovery from a stream disconnect. No watts/battery-life claim is made.

## Confirmed source path

- `packages/reader_runtime/lib/src/reader_runtime_screen.dart` associates a platform cadence probe with a mounted vertical Reader, independently of whether the page is static or motion has stopped.
- `packages/reader_runtime/android/src/main/kotlin/dev/zic/readerruntime/ReaderRuntimePlugin.kt` starts monitoring from `startFrameCadenceProbe`. Its Choreographer callback reposts itself on every vsync while monitoring is active. Starting the probe also attaches Window FrameMetrics observation.
- `packages/reader_runtime/lib/src/flutter_reader_platform_frame_cadence.dart` drains diagnostics with a two-second periodic timer.
- Not calling Flutter `scheduleFrame` does not make this passive or power-neutral. A bounded ring bounds memory, not callback frequency.

## Change and ownership

The adapter defaults to disabled using the compile-time `ZIC_READER_FRAME_CADENCE_DIAGNOSTICS` boolean. Disabled `start()` returns before plugin attachment, native monitoring and timer creation. `drain()` and `stop()` remain inert for that never-started instance.

To run a bounded platform-cadence investigation, use:

```sh
ZIC_READER_FRAME_CADENCE_DIAGNOSTICS=1 ./tool/build_android.sh profile
```

The build script maps shell `1` to Dart `--dart-define=ZIC_READER_FRAME_CADENCE_DIAGNOSTICS=true`; ordinary debug/profile/release builds do not opt in. This is not a Reader/UI eligibility gate. Passive Flutter frame timing, task/loading Trace, cache and decode windows, transport cancellation, `NetLane`, presentation and scroll behavior are unchanged. No native functionality is deleted. Do not infer absence of frames from absence of these opt-in diagnostic events.

## Other paths inspected

- Pipeline playback wakes are deadline-driven; `UploadSession.present` clears the deadline for authoritative zero-duration static output. No new playback-loop defect is established by this inspection.
- External static-presentation prewarming uses an in-flight token per decode identity, checks token identity and current demand on completion, and records failed detached prewarming rather than indefinitely retrying it while the same demand remains. This is not proof against all demand churn; trace comparison is still needed.
- Existing offscreen subtree TickerMode and resource-window ownership remain unchanged.

## Regression evidence

- New test `normal Reader does not start an active platform cadence probe` failed before the change: mock platform calls included start, drains and stop. Flutter initialized successfully; this was not an environment failure.
- After the change, `packages/reader_runtime` passed all 26 tests. The existing explicit-enabled test still verifies native sample mapping to the shared trace clock.
- `flutter analyze` for that package returned exit 1 with 13 info-level diagnostics and no errors; this is not reported as a clean analyzer pass. The adapter's `prefer_initializing_formals` pattern predates the change.
- Shell syntax, dev.310, dev.313, dev.319 observation-boundary checks and ReaderRuntimePlugin Kotlin compilation passed in focused validation.
- Final `LD_PRELOAD=/lib/x86_64-linux-gnu/libsqlite3.so.0 bash tool/check.sh --require-toolchains` completed with exit 0: 27 Dart test invocations, **1,923 passed / 3 existing skips**, Rust **22 passed**. Android/Kotlin compile contracts and documentation/architecture gates passed. The gate accepts info-level analyzer findings (721 across 22 analyses); it does not resolve the independent analyzer's exit-1 report or prove a fresh fixed APK was installed.

## Device evidence limitations

The first device run built and installed a fresh baseline Profile APK, but was interrupted by API 429 (`usage_limit_reached`) before returning a validated report. Baseline artifacts are under `.log/static-power/`; build hash is in `profile-apk.sha256`. Partial CPU summaries alone do not prove Reader entry, static content or actual scrolling and must not be used as acceptance.

The first same-protocol continuation ran on **M2007J1SC / 72b08a1c**, not the earlier cold-start failure device. It proved Reader entry but stayed in paged mode: 39 logical-position observations remained at 46.0 while a vertical gesture reached the overlay. Its CPU windows and `.log/static-power/baseline/zic-debug-trace-2026-09-22T10-51-44.jsonl` are **not** static-vertical acceptance; that run did not build/install the fixed APK. The trace classifies two pages as static, so WebP format or unknown remaining chapter pages do not justify declaring that no static workload exists.

The targeted continuation explicitly selected the comic's vertical reading override. The sampled page neighborhood (44–49) reports `animated=false`, `frameCount=1`, `complete=true`, and actual logical positions change in vertical mode. It compared the baseline with a fresh `./tool/build_android.sh profile` build installed using `adb install -r` (no diagnostics environment override). Fixed APK SHA-256: `6da9fbad1395703d18d7d50e7a676f6b2baf36660f5cd757aa6112f331412ccf`. The device now contains this fixed Profile APK, not the earlier baseline.

Device-runner CPU report (percentage of one core, sampled `/proc` ticks; nominal 20-second windows):

| Window | Baseline main | Fixed group 1 main | Fixed group 2 main |
| --- | ---: | ---: | ---: |
| Idle | 6.45% | 0.00% | 0.00% |
| Alternating vertical scroll | 23.05% | 22.30% | 20.10% |
| Post-stop idle | 6.10% | 0.00% | 0.00% |

Zero is the sampled tick-resolution result, not zero CPU/power. Raw CPU files contain SAMPLE 0–20 but no per-sample monotonic timestamps; 20 seconds is the sampler's nominal interval, not a verified exact wall duration, and CPU windows cannot be aligned precisely with application trace time. Totals based on common endpoint threads omit some short-lived workers. Scroll raster CPU remained about 16–17%; observed page ranges differ (baseline roughly 46–47.79 versus fixed group 1 46–49.13), so these scroll figures are not an equivalent-motion improvement claim. The active probe is the intended code difference, not an unrelated measurement intervention, but differing workload history and sampling limitations prevent attributing every CPU difference solely to it. Baseline exports contain the active cadence summaries; fixed exports lack them as expected, but that absence alone is not the CPU evidence.

Artifacts:
- `.log/static-power/baseline-vertical/zic-debug-trace-2026-09-22T11-25-03.jsonl`
- `.log/static-power/fixed-vertical/zic-debug-trace-2026-09-22T11-31-12.jsonl`
- `.log/static-power/fixed-vertical/zic-debug-trace-2026-09-22T11-35-30.jsonl`
- Raw CPU samples/conditions and APK hash are in the matching directories; original settings are in `.log/static-power/vertical-run/settings-original-ui.xml`.

After sampling the effective original settings were restored (`comicSpecificEnabled=false`, adaptive enabled), with the app back on Home. The app recalculated the LTR geometry confidence from 89% to 100%; the report does not claim a byte-identical settings rollback. No cache, download data or resource waterline was cleared or changed. CPU time/wakeups are power proxies, not watts; charging current and missing diagnostic events are not power acceptance.

## Final trace findings

- The valid baseline has 240 exported `platformFrameCadenceSummary` batches totaling 28,014 intervals over the whole trace. This is neither a 20-second window count nor a count of Flutter rendered frames. Fixed builds do not enable that diagnostic probe; its absent trace output alone does not prove zero work.
- Baseline / fixed group 1 / fixed group 2 contain 7 / 7 / 13 classified static active pages and 7 / 7 / 13 pipeline timing samples. Static classification is supported by `animated=false`, one complete frame and actual presentation, not by the trace format field (which is null); UI JPEG labels are separate evidence.
- No self-sustaining repeated load/cancel/retry loop was observed. Each fixed export contains three distinct download starts and three completed HTTP 200 source reads, `sourceRetryUsed=false`, observed `maxConcurrent=1`, without a second start of the same provider or a retry chain. These are finite neighboring-page/prewarm reads, not proof the full scene has no network activity. Lifecycle demand detach events are not transport cancellation counts.
- Fixed group 2 has one `reader-version-check-failed` / `Venera resource returned non-image bytes` event at 260153398 microseconds. It is a remaining source/version-refresh failure, not fixed or hidden by this change; no retry chain accompanies it. Do not report all samples as zero-failure.
- Decode/present timing still predominantly attributes work to native decode; no new decode scheduling change is justified by these traces. Scroll raster and total app CPU did not improve consistently.
- Exported counts are coalesced and the traces have different lengths. There is no aligned SurfaceFlinger/Perfetto capture or measured power, so no SF dropped-frame rate, watts or battery-life improvement is claimed.

Analyzer outputs are `.log/static-power/vertical-run/analyze-{baseline,fixed-g1,fixed-g2}-*.txt`; CPU raw/summary artifacts are in the baseline/fixed directories above. Analysis completion used run `16e140e3-046d-41f0-918a-35f69bfa64cc`; the full verification report used run `9736167b-2376-41b3-a820-091b72b4bb74`.

The unrelated `.gitignore` modification belongs to the user and is outside this change.

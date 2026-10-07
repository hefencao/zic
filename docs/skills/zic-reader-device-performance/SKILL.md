---
name: zic-reader-device-performance
description: Repeatable real-device ZIC Reader startup, playback, and bidirectional preupload validation without confusing debug-build cost or stale Home accessibility semantics with product regressions.
metadata:
  version: "1.2.3"
---

# ZIC Reader device performance

Use this skill for `~/projects/zic` real-device performance validation. Read `AGENTS.md` first and preserve the current worktree. Do not run `dart format`, uninstall the app, clear app data, or change Reader waterlines merely to improve a test.

## Build truth comes before performance truth

Absolute startup, decode, frame, or CPU timing is valid only from **Profile/Release Dart with release native media**. The canonical profiling build is:

```bash
cd ~/projects/zic
./tool/build_android.sh profile
adb install -r apps/app/build/app/outputs/flutter-apk/app-arm64-v8a-profile.apk
```

`profile` intentionally maps the Rust/native build to `release`. A normal `./tool/build_android.sh debug` builds both Flutter and native debug artifacts and is unsuitable for performance conclusions. A debug Flutter APK with manually restored release native media is useful for functional tracing, but its Dart gzip/JSON/model/Widget CPU times are still not product performance evidence.

Record the exact build command in every device-performance result. Do not infer Flutter mode from Android's `DEBUGGABLE` package flag: Flutter profile APKs can still be debuggable.

## Reader-entry preflight is event-gated, not sleep-gated

For a steady-state Reader performance baseline, do not tap a Home/history item merely because Home is already visible. Bootstrap Home can render from the snapshot before the durable library/download composition has been adopted. This window is build-mode dependent: Debug Dart can take seconds longer than Profile/Release, so a fixed `sleep 1` or `sleep 3` is not a correctness boundary.

For the steady-state Reader performance baseline, before the first Reader tap require both startup events from the **current process**:

- `[zic-startup] ... durable-services-ready`
- `[zic-home] ... services-handoff-complete mode=authoritative-reload`

Use `python3 tool/prepare_reader_device_test.py --mode profile` (or `release` / `debug`) to install the exact selected APK with `adb install -r`, cold-start it, and wait for those events. The helper has a longer timeout for debug, but timeout length is only an upper bound; readiness is the event predicate itself. If the gate times out, stop and diagnose startup instead of tapping through a half-adopted Home.

The helper also validates that the Home accessibility tree contains the reading-history section after authoritative handoff. Do not use bootstrap history cards as a steady-state performance target.

Cold-handoff correctness is a distinct regression scenario, not an invalid user action: real users MAY tap a bootstrap history card before these readiness events. App composition must paint the deferred route, await core-service readiness and Home adoption, then create Reader capabilities without capturing retired bootstrap owners. Test this deterministically with a blocked service-handoff future; any separately labeled early-entry device reproduction must prove the selected card/input and record whether the tap preceded core readiness. Do not use the performance helper's readiness wait as proof this race is fixed, and do not attribute its former `chapter download service is closed` failures to invalid user timing.

ADB input must also target the real app display explicitly. scrcpy or other tooling may create a virtual display; an unqualified `adb shell input tap/swipe` can therefore inject into the wrong display while screenshots still show display 0. On the current MIUI device, the source-first form is the verified working syntax: use `adb shell input touchscreen -d 0 tap ...` / `swipe ...` for touch and `adb shell input keyboard -d 0 keyevent ...` for Back or other keys, unless `dumpsys activity` proves the ZIC task is on a different display. Do not use the superficially similar `adb shell input -d 0 tap ...` form as test evidence unless a harmless control round-trip has first proved that it is actually delivered on that device. Never use an unqualified tap/swipe in a Reader performance run.

Before the first destructive or Reader-targeted input in a new device session, prove injection with a harmless Home navigation round-trip: resolve the current Home/Bookshelf tab bounds, tap Bookshelf with the source-first command and require `selected=true`, then tap Home and require `selected=true`. A zero exit code does not prove delivery. If the control state does not change, stop the performance run and mark input unverified; confirm the actual page, awake/focus state and fresh target before attributing a product defect. A harmless system-menu navigation can compare input methods. A different result from a same-point short press is an input-method observation, not authorization to tune Reader behavior.

For read-only VM input diagnosis, require `getVM.pid` to match the current app PID. Read actual collection contents: a `ListQueue` uses head/tail/table, while a map exposes its length/associations. The number of object fields is not a queued-event count. Old ANR/WaitQueue flags cannot describe a new input stream; a missing DOWN must remain missing evidence.

## Device hygiene

Preserve user data with `adb install -r`. Reuse the APK in the current build output instead of copying it into each test directory. Capture screenshots only when they answer a visual question, and overwrite the current file for that purpose:

```bash
mkdir -p .log
adb exec-out screencap -p > .log/current-reader.png
```

Do not write temporary screenshots or UI XML into `/sdcard` root. If accessibility inspection is needed while Home is known to be topmost, stream it without a device file:

```bash
adb exec-out uiautomator dump /dev/tty
```

Trace exports belong in the configured `Download/Debug` directory. Verify that the action created a new export before pulling it. Keep original user-reported traces and the minimum before/after inputs for an open issue; overwrite current working traces for repeated checks. After verification, delete redundant traces, stale screenshots/XML/APKs, completed backup copies and temporary worktrees, including those in private cache. A completed check needs a short result in the existing status, not another permanent evidence directory or manifest. Temporary probes must clean their work directory on success or failure; moving a whole batch to private cache is not cleanup.

For VM profiling, collect allocation traces only when the selected allocation tracing is enabled. Before saving CPU/allocation samples, retain referenced function/code descriptions and remap stack indices, preserving all sample events, timestamps and class counts. An unreferenced full VM symbol table is not a necessary reproduction input.

## Reader state: never infer it from Home semantics alone

Flutter/Android accessibility can preserve Home nodes while Reader covers Home. Therefore all of the following are invalid as sole evidence that Reader failed to open or already exited: seeing the Home tab, finding a history-card node, or finding a Home button in `uiautomator` output.

Confirm Reader entry from app evidence such as the chapter hydrate/Reader session event plus the selected comic's media open and `pageHostMounted` / `firstFrameReady` / presentation events. Confirm exit with Reader retention/dispose evidence and, when interaction correctness matters, prove that a top-level Home control actually receives input after Back.

Never choose a cover with a hard-coded coordinate. Resolve the exact, unique visible target from current accessibility XML and tap the intersection of its label bounds with its clickable ancestor, then verify the resulting page. A grouped ancestor may span adjacent controls, so its center is not a valid target. Coordinates are acceptable only for the subsequent continuous swipe gesture after the Reader viewport is already confirmed.

For synthetic paged Reader navigation on the current 1080x2340 device workflow, the swipe path MUST stay on `y=900` (for example `900,900 -> 180,900` or the reverse) and MUST NOT cross the Home reading-history strip. Do not issue any swipe until Reader entry is already confirmed by Reader trace/session evidence. If Reader entry has not been proved, stop and re-resolve the intended cover instead of "trying a swipe". A swipe performed while Home is still active is a test failure and its resulting navigation/history state MUST NOT be used as product evidence.

## Bidirectional preupload validation

Do not test by swiping one direction forever. A valid previous-target test is:

1. Enter a known cached animated chapter and confirm Reader from trace/app signals.
2. Make at least three committed page moves in one direction. Confirm the `pageCurrent` indexes, rather than assuming physical left/right is logical next for every Reader mode.
3. Exit Reader and confirm Home is actually interactive.
4. Re-enter the same reading-history item so its current page is the newly persisted position.
5. Move back toward the pages just visited at least three times.
6. Export the trace immediately.

Analyze the trace with both tools:

```bash
python3 tool/analyze_frame_pipeline_trace.py .log/<trace>.jsonl --limit 30
python3 tool/analyze_reader_navigation_trace.py .log/<trace>.jsonl
```

The navigation analyzer reports the **stable direction at gesture start**. The important reverse cases are rows whose `startRole` is `previous`: the target index is opposite the still-stable `readDirection`. Those rows test whether active-gesture target coverage can pre-present the previous page *before* the 3/7 stable-direction classifier flips. Do not weaken or bypass the 3/7 classifier to make this test pass.

For preupload, separate media readiness from PageView gesture/settle. `mountToFirstFrameMicros` can include gesture geometry and is not by itself proof of a decode regression. Inspect `pageOutputPrewarmed`, frame upload/presentation, native decode, source wait, and the transition/current timing together.

## Animated playback validation

Use `framePipelineTiming.nativeDecodeMicros` for native decode cost. Do not use a debug-native APK for this metric. For the current M2007J1SC baseline on the cached Ani Collections workload, release-native normal foreground decode is roughly in the 40–50 ms range; a sudden ~450–500 ms median is a build/runtime problem until proven otherwise.

Do not reopen refresh-rate investigation unless fresh trace evidence makes display/vsync the dominant unexplained stage. Existing low-build cadence gaps and media decode are separate lines of evidence.

## Active platform diagnostics and static-power measurements

Ordinary builds keep the Android Choreographer/Window FrameMetrics probe off. It posts a callback every vsync and drains every 2s even on a still page; observation-only does not mean power-neutral. Passive Flutter frame timings and task/loading Trace remain enabled independently. For a bounded cadence investigation only, explicitly build with `ZIC_READER_FRAME_CADENCE_DIAGNOSTICS=1 ./tool/build_android.sh profile` (maps to Dart define `ZIC_READER_FRAME_CADENCE_DIAGNOSTICS=true`), and record that opt-in in the result. Never compare its CPU/power sample against an ordinary build without disclosing the observer difference. Restore an ordinary freshly built APK afterward; absence of platform cadence events in an ordinary build is expected, not proof that no frames occurred.

For static-power work confirm an actual static image chapter and vertical Reader entry from app evidence. Keep separate settled idle, controlled scrolling and post-scroll idle windows; record thread CPU time/wakeups and device conditions. CPU is a power proxy, not watts. Do not substitute Home or animated content if the target cannot be proved.

## Cold-start validation

Use `am force-stop`, never data clearing. Measure at least three independent starts:

```bash
adb shell am force-stop dev.zic.zic
adb logcat -c
adb shell am start -W -n dev.zic.zic/.MainActivity
```

Then inspect `[zic-startup]` and `[zic-storage] home-snapshot-*` logs. Keep these boundaries separate:

- Android `TotalTime` / `WaitTime`;
- Home snapshot stored-byte read + gzip expansion;
- JSON decode;
- snapshot model decode;
- Flutter platform UI displayed / visible Home window;
- library and download-composition open.

A large debug-Dart snapshot duration is not a product regression until reproduced in Profile/Release. On 2026-09-13 the identical 320 KB gzip / 3.31 MB JSON snapshot took 1.255–1.334 s in debug Dart but only 87–99 ms in profile Dart; raw device file read was ~30 ms.

## Stop conditions

Prefer diagnosing the owner of a delay over adding another gate. Do not change 7/3 download, 2/1 decode, 3/7 direction, cache authority, or lifecycle ownership solely because synthetic ADB gestures look slow. If the trace contradicts the current hypothesis, stop and reclassify the problem before editing product code.

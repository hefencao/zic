# Active native decode Reader retirement acceptance

The entry opens only its private input in `dev.zic.activenativeretirement`;
it does not open user stores or require another user-data backup for this case.
The runner verifies the installed ordinary APK, installs a separate test
package, collects results, uninstalls it and returns to the ordinary Home.

Build from `apps/app/android` with the external init script. It changes only
this invocation's test applicationId, without editing production Gradle:

```sh
TMPDIR=/path/to/disk/tmp ./gradlew :app:assembleProfile \
  -Ptarget-platform=android-arm64 -Psplit-per-abi=true \
  -Ptarget=/absolute/zic/apps/app/test/device_acceptance/reader_active_native_retirement.dart \
  -Pdart-obfuscation=false -Ptrack-widget-creation=false -Ptree-shake-icons=true \
  --init-script ../test/device_acceptance/reader_active_native_retirement.gradle
```

Supply a sealed, large static lossless WebP whose actual native fragment decode
lasts long enough to cover route exit. An incompressible 4096×4096 palette image
was used for the initial device acceptance (16,784,452 bytes, SHA-256
`524dd6b2464e503bc003c378b93b64dddc1b15754c5eff41fe632fb064cac264`).
The runner records the chosen file hash and verifies its private device copy;
the large input is not included in the repository. A faster decode or delayed
exit that cannot satisfy the measured execution proof fails acceptance.

```sh
python3 apps/app/test/device_acceptance/reader_active_native_retirement.py \
  --serial DEVICE_SERIAL --fixture-apk /path/to/fixture.apk \
  --ordinary-apk /path/to/installed-ordinary.apk \
  --input /path/to/static-lossless.webp --input-sha256 SEALED_SHA256 \
  --out /path/to/evidence
```

Both cases use the real PipelineReaderSessionHost, ReaderRuntimeScreen,
NativePipelineMediaRuntimeFactory, native source/cursor and texture bridge.
The cursor observer preserves TaskControl and priority promotion, delegates
the original cursor operation and returns its original Future unchanged.
Uploader and platform observers also return original Futures; they add no
delay, admission gate, queue, retry, network authority or source lock.

At the actual retained-route event, the cancelled original Future must still
be pending and its native cursor/source alive. After completion, one Rust
`Instant`-measured phase of duration D must prove execution at that event C:
`E-D+1000 < C < B+D-1000`, where B/E bracket the original delegate call.
That single phase is wholly inside B/E, so the interval lies inside actual
native work. The oracle never adds potentially nested phase durations or uses
the worker's outer Stopwatch as its execution proof. These observations are
test assertions only and never become production scheduling inputs.

The drain case must release the cursor only after the original Future returns,
discard its late frame and dispose the source without another Reader event.
The rapid reentry case must reuse the exact session before old work completes,
present a new cursor's frame0 through an actual Texture with no extra input
read, and keep its renewed source demand safe from the old retirement callback.
After the final exit all cursors, sources and returned frames must be disposed,
the original native composition must shut down and no taskFailed may occur.

This covers active native decode retirement for the supplied input and exact
warm session. Active upload, real source revision/carrier replacement, GPU/fence
retirement, Android background loss, original19/20 loading, input latency and
final physical display performance still require separate evidence.

For the remaining high-resolution current handoff, build the same entry with
`-Pdart-defines=WklDX05BVElWRV9DVVJSRU5UX0hBTkRPRkZfT05MWT10cnVl` and run
with `--handoff-only`. This mode does not repeat the two accepted route cases.
It uses the existing small static fixture for pages0/6 and symlinks one sealed
large input for the background pages, without duplicating the large body.
The actual mounted ReaderController requests page6 while page1 native decode
is active. Current frame0 must reach native Texture and the real first-frame
callback before that old task returns. One Rust internal phase must prove
old physical execution at both the navigation command and current first frame;
the cancelled cursor/source remain alive and retire only after its original
Future completes. No observer changes a Future, control, queue or capacity.
This measures owner execution and application presentation, not finger latency
or final physical display.
Command observations are bounded samples; successful cases do not collect
logcat. Keep the scoped conclusion and remove completed private inputs/results.

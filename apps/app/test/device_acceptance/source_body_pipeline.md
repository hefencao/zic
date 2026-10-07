# Source body persistent Pipeline acceptance

This separate test entry extends the source transport evidence through the
production DownloadSession, persistent artifact index and actual PNG Reader
presentation. Keep the original nine source transport cases and their evidence
unchanged.

After preparing the production Android bridges and native dependencies, build
from `apps/app` and preserve the APK before another build:

```sh
flutter build apk --profile --split-per-abi \
  --target test/device_acceptance/source_body_pipeline.dart
```

Run with an ordinary production APK bearing the same signing certificate:

```sh
python3 apps/app/test/device_acceptance/source_body_pipeline.py \
  --serial DEVICE_SERIAL --fixture-apk /path/to/fixture.apk \
  --restore-apk /path/to/ordinary.apk --out /tmp/zic-source-body-pipeline-result
```

Each canonical/isolated source transform covers three distinct cases:

- Actual loopback HTTP and production rhttp/source/Service/Binder/file delivery
  enters the original physical transfer owner, commits and promotes an exact
  automatic READY artifact, then presents through ImportedImageChapterScreen.
  Independently computed artifact CRC32 and SHA256 must match the durable index
  and claimed source body; the body lease must be released and removed.
- Reader unmount and complete retention/transfer/native/store shutdown are
  followed by new store, cache, transfer and raster owners on the same directory.
  The unchanged exact READY must actually present with no source loader call,
  origin HTTP request, new body claim, downloadStarted or taskFailed event.
- A real TCP response sends headers and an incomplete body. Reader unmount and
  retention/physical teardown must cancel the original controlled source call,
  wait for its exit and TCP peer close, leave an idle NetLane and publish neither
  READY nor a presentation frame. The fixture does not delay a production read
  Future, synthesize response bytes or add a scheduler/eligibility gate.

Only already-presented test routes are held briefly for runner screenshots;
these holds are not performance measurements. The temporary JavaScript source
and persistent directories are outside the installed roster and user store.
The runner preserves app data, records complete fixture traces and restores the
ordinary APK in `finally`. Export and compare full user backups before and after;
only export creation time may differ.

This scope proves PNG external-static presentation, not native WebP output,
every transport variant, real external-origin/source-client/CookieJar behavior,
input/canonical allocation removal, live streaming or final display performance.

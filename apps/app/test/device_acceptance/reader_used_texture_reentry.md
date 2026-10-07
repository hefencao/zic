# Native used-texture Reader reentry acceptance

Build the separate entry using the current production dependencies:

```sh
TMPDIR=/path/to/disk/tmp flutter build apk --profile --split-per-abi \
  --target test/device_acceptance/reader_used_texture_reentry.dart
```

Run with an ordinary same-certificate APK for automatic restoration:

```sh
python3 apps/app/test/device_acceptance/reader_used_texture_reentry.py \
  --serial DEVICE_SERIAL --fixture-apk /path/to/fixture.apk \
  --restore-apk /path/to/ordinary.apk --out /path/to/evidence
```

The runner stages the existing sealed static/animated WebP inputs privately,
checks their device hashes and removes them before restoring the ordinary APK.
Back up all user data before/after; this entry opens only the temporary inputs.

The real PipelineReaderSessionHost and ReaderRuntimeScreen consume the same
NativePipelineMediaRuntimeFactory throughout three entries of each chapter.
The exact Reader session must be retained, while every used texture ID is new.
Each actual mounted Texture must have successful platform create/present
replies; animation must advance native presented frames. Route exit must remove
the view, finish the native output release reply well before retention TTL,
reject access to the old output, and produce no later present of that ID.
Composition shutdown retires all created outputs, including unused prewarms.

The test binding observes the original platform messages without replacing
their Futures or modifying bytes, replies, playback, retry or scheduling.
The release reply proves the output retired and its release was queued to the
main looper. Production SurfaceProducer.release executes in that posted
callback; a reply alone does not measure physical GPU/fence retirement. The
next actual create runs on the same main looper after the queued cleanup.

This verifies used-texture recreation across exact-session warm route reentry
for the selected native static/animated inputs. It does not prove source
revision/carrier replacement, cancellation during active decode/upload,
Android background surface loss, original19/20 loading, or final display timing.

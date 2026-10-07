# Venera output encoding lifetime acceptance

This fixture runs the target APK's actual image-only WebViews, Image primitives,
PNG encoder and worker admission. A held output encoder proves that another
worker can finish while encoding remains live. Cancellation must retain capacity
until encoding and JavaScript cleanup finish; close must join both encoders
before reclaiming their Bitmaps. Encoder failure and executor rejection must
settle once and leave no pending inputs, images or assignments.

The body cases inject controlled late `RuntimeServiceBodyReference` tokens and
verify exactly one discard through the original body callback. They do not
create, seal or claim files; real file/Binder acceptance remains the separate
`binder_body` fixture. This fixture changes no source settings or library data.
The borrowed executor has the same type as the native host executor and is
never owned or shut down by the transform runtime.

An unminified ordinary Profile APK is required for production class reflection.
No keep rules or diagnostic code are added to the target APK. The same overlap
case supports the prior synchronous constructor for failing-first evidence.

```sh
python3 apps/app/test/device_acceptance/android/venera_transform_encoding/run.py \
  --out /tmp/zic-transform-encoding-fixture --run --serial DEVICE_SERIAL \
  --profile-apk /path/to/profile.apk --restore-apk /path/to/release.apk
```

The runner verifies signing certificates and installed APK hashes, preserves
app data with `install -r`, restores the supplied APK in `finally`, removes its
probe and opens Home. `--cases overlap` selects the failing-first scenario.
`result.json` records commands, artifact hashes and native case evidence.

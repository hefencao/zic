# Actual Dart runtime-body consumer acceptance

Build the test-only entry from `apps/app`; it uses the production native bridge,
separate Android Service and Dart channel/file consumer. It does not open the
user library, download index, settings or installed-source roster.

```sh
flutter build apk --profile --no-pub --target-platform android-arm64 \
  --target test/device_acceptance/runtime_body_consumer.dart
```

The nine cases cover canonical/isolated large-body bounded reads, actual pending
Dart File-read Futures at body disposal, stream cancellation and session close,
and source-process loss/reactivation while a claimed Dart consumer continues.
IOOverrides and BinaryMessenger only observe actual operations and forward
unchanged messages. There is no fake read data or delayed Future. A missed
pending-read observation is a fixture timing miss, not a product defect.

Supply a prebuilt debuggable Profile fixture and ordinary APK with the same
signing certificate. The runner reads only the fixture result through `run-as`:

```sh
python3 apps/app/test/device_acceptance/runtime_body_consumer.py \
  --serial DEVICE_SERIAL --fixture-apk /path/to/fixture.apk \
  --restore-apk /path/to/ordinary.apk --out /tmp/zic-dart-body-result
```

The runner preserves app data, records each actual device result and installed
APK hash, and restores the ordinary APK in `finally`. Export user data before
and after the run and compare complete chapter payloads and all data domains.
The fixture stores only its own result file in the native app support directory.
Save prior results before rerunning.

The real read Future verifies admitted Dart I/O completion before close/release;
it does not manufacture or prove a long blocked kernel read. These synthetic
transform cases do not prove real HTTP cancellation, host input allocation
removal, canonical whole-byte removal, live streaming, Cookie/POST behavior,
original Reader loading or final-display performance.

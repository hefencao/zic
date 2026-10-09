# Real Binder body lifetime acceptance

This fixture runs the production `PluginRuntimeServiceClient` against the actual
Android `:zic_plugin_runtime` Service. It requires an unminified Profile APK with
the existing production class names. It does not add reflection keep rules,
modify the production APK or install a catalog source in the app.

The same deterministic PNG exercises canonical and isolated transforms, large
request/response packet files, negotiated raw bodies, physical hash cancellation
and close, session close, source process death during production and after claim,
host restart and the original 65-second RPC timeout. The native/file read checks
are separate from the Dart consumer, live network, input allocation and final
physical display criteria. The hash cases must observe a live physical claim;
a missed timing sample fails the fixture and is not proof of a product defect.

Use Android SDK platform/build-tools 36 and a JDK with `javac`. Build only:

```sh
python3 apps/app/test/device_acceptance/android/binder_body/run.py --out /tmp/zic-binder-body-fixture
```

To run, provide the device serial, a prebuilt Profile APK and the ordinary APK to
restore. All three APKs must have the same signing certificate. The script keeps
app data, restores the supplied APK in `finally`, removes the probe and opens
Home. `result.json` records installed artifact hashes and each native result.

```sh
python3 apps/app/test/device_acceptance/android/binder_body/run.py \
  --out /tmp/zic-binder-body-fixture --run --serial DEVICE_SERIAL \
  --profile-apk /path/to/profile.apk --restore-apk /path/to/release.apk
```

`--cases normal` runs a shorter transport check. `host-stage` and `host-reopen`
must run consecutively: the first leaves one actual claimed lease, and the next
verifies that a new host sees it intact before the original client removes it.

`--cases eh-initial-replay eh-initial-terminal` instead reads the actual installed
`venera:ehentai` payload without opening the library or artifact index. Each case
starts a cold Service and kills its physical process while the original
activation remains pending. It requires the same pending object, request ID and
encoded payload across exactly one fresh Binder generation. The first case
establishes the real EH session; the second kills the fresh generation and
requires one terminal result with no third bind. A missed pending-work timing
sample is a test limitation. These deliberate process deaths do not diagnose a
spontaneous crash or LMK. The source manifest, payload and preferences are not
deleted; only task-owned temporary files are cleaned.

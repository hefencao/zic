# Actual source transport acceptance

Build the test-only entry from `apps/app` with the production Android bridges
and native dependencies already prepared by the repository build workflow:

```sh
flutter build apk --profile --no-pub --target-platform android-arm64 \
  --target test/device_acceptance/source_body_transport.dart
```

Copy the resulting `build/app/outputs/flutter-apk/app-profile.apk` to a separate
fixture path before another build. Supply an ordinary APK with the same signing
certificate; its entry point must be the production app, not this fixture.

```sh
python3 apps/app/test/device_acceptance/source_body_transport.py \
  --serial DEVICE_SERIAL --fixture-apk /path/to/fixture.apk \
  --restore-apk /path/to/ordinary.apk --out /tmp/zic-source-body-result
```

The fixture follows actual loopback HTTP through production rhttp, source
adapter, SourceResourceTransport, separate Venera Service/Binder transform,
claimed Dart file and ByteResponse. The original NetLane holds each task.
Canonical and isolated transforms each cover full consumption, matching Range,
mismatched validator and discard before listening. The ninth case cancels an
unfinished HTTP input and waits for typed cancellation and actual TCP peer exit.
The server sends a real response prefix and controls its own socket; it does
not delay production read Futures or substitute transport bytes.

The server checks nonempty synthetic Cookie/POST and source User-Agent
precedence. BinaryMessenger forwards actual messages unchanged. This selected
transform subset does not prove every SourceResourceTransport variant, full
DownloadSession/Pipeline, external-origin/source-client cancellation, real
CookieJar/POST/interceptors, live streaming, host input/canonical allocation
removal, original Reader loading or final display performance.

The temporary JavaScript source is outside the installed-source directory. The
fixture does not open the user library, artifact index, settings or source
roster. Its runner records hashes and results, preserves app data and restores
the ordinary APK in `finally` after replacement begins. Export backups before
and after the run and compare complete chapter payloads, URI and progress
fields, and all other exported domains; only export creation time may differ.
Preserve prior fixture results before rerunning.

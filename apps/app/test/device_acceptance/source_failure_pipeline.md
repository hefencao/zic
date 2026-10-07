# Actual source failure and retry acceptance

Build this independent test entry from `apps/app` after preparing the production
Android bridges/native dependencies. Use a disk-backed `TMPDIR` when `/tmp` has
insufficient room for compiler outputs, and preserve the built fixture APK:

```sh
flutter build apk --profile --split-per-abi \
  --target test/device_acceptance/source_failure_pipeline.dart
```

Supply a normal production restore APK with the same signing certificate:

```sh
python3 apps/app/test/device_acceptance/source_failure_pipeline.py \
  --serial DEVICE_SERIAL --fixture-apk /path/to/fixture.apk \
  --restore-apk /path/to/ordinary.apk --out /tmp/zic-source-failure-result
```

The fixture mounts ImportedImageChapterScreen with original production source
adapter, rhttp, separate Venera Service/Binder and physical download owners.
Its temporary JavaScript source and persistent stores never open the user
library, preferences, artifact index or installed-source roster.
Browse, comic and chapter calls generate the production `venera-resource:`
deferred page locators. Source-plan rejection is thrown by `onImageLoad` at
that page entry, preserving the separate HTTP artwork compatibility behavior.
The response observer accepts absent body-delivery diagnostics and returns the
original response unchanged.

Six cases exercise actual source-plan/transform exceptions, non-image HTTP,
one real truncated TCP input followed by success, repeated truncated input
until the existing Reader RetryPolicy exhausts, and route teardown during the
first real retry backoff. The server controls its own sockets, not production
read Futures. The fixture does not inject retry policy, timers, source failure
envelopes or another scheduler.

Source failures must remain typed non-retryable errors with one terminal
`downloadState=failed` after physical task retirement. Semantic rejection uses
that existing cleanup branch rather than the generic `taskFailed` trace;
the fixture checks both event counts without changing production observability.
Network retries must consume only the original policy's attempt
budget. Failed input must not become READY or a frame; success must actually
present and promote its verified artifact. Each outcome is observed for six
seconds with unchanged current demand and normal scheduled layout frames.
The observer records the original delegate error without wrapping it; rhttp
EOF errors acquire `ErrorCode.network` inside the production download owner.
The exhausted case checks that typed terminal snapshot directly, while the
transient case checks the original attempt trace and successful artifact.
Cancellation must join owner shutdown and prevent a retired retry sleeper from
opening another HTTP request. Screenshot holds follow the completed outcome
and are not performance measurements.

The runner records complete fixture traces/screenshots and restores the normal
APK in `finally`. Compare complete backups before/after; only export creation
time may change. This scope does not replace real Mihon/Venera source, real
external-origin/CookieJar, process-restart, original19/20 loading or final
display acceptance. Preserve the earlier body-transport and Pipeline evidence.

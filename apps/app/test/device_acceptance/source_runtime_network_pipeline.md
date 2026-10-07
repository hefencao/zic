# Actual source-runtime resolver network acceptance

Build the independent entry with the production Android/native dependencies:

```sh
TMPDIR=/path/to/disk/tmp flutter build apk --profile --split-per-abi \
  --target test/device_acceptance/source_runtime_network_pipeline.dart
```

Run the companion Python runner with a same-certificate ordinary restore APK:

```sh
python3 apps/app/test/device_acceptance/source_runtime_network_pipeline.py \
  --serial DEVICE_SERIAL --fixture-apk /path/to/fixture.apk \
  --restore-apk /path/to/ordinary.apk --out /path/to/evidence
```

The temporary Venera source requests the network capability and generates its
Reader page locators through the production browse/comic/chapter APIs.
Its `onImageLoad` calls the actual `Network.post` API in the separate source
process. The original Kotlin bridge and source-process Dart/rhttp resolver
fetch a JSON request plan from a real loopback HTTP server; the host then
fetches and transforms the PNG media through the original Pipeline owners.

Four cases cover one real resolver EOF then success, repeated resolver EOF
until the original default attempt budget exhausts, route teardown while the
resolver is physically reading a held TCP body, and teardown during the first
real retry backoff. EOF failures must arrive at the source adapter as typed
`ErrorCode.network` with `runtimeRetryable=true` even when the error message
does not match the legacy network keyword classifier. The observer records
errors and returns the original response without changing either.

Each stable success/terminal result and each cancelled composition is observed
for six seconds. Successful input must produce exact verified durable READY
and an actual PNG first frame; failed/cancelled work must not produce media
HTTP, READY or a frame. Active cancellation must physically close the server
peer before the post-exit observation. Resolver operation/request counts and
original owner trace counts detect second retry loops. Explicit Cookie,
User-Agent and POST body must survive both actual HTTP stages; runtime control
headers must stay out of origin requests.

The fixture uses private temporary stores and never opens the user library,
preferences, artifact index or installed-source roster. The runner preserves
traces/screenshots and restores the ordinary APK in `finally`. Compare full
user backups before/after. This scope does not prove real external origins,
Android CookieJar, Mihon clients, canonical/onResponse whole-input allocation,
native WebP, live streaming, production theme, original19/20 loading or final
display performance. Earlier accepted fixtures stay separate and unchanged.

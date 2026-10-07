# Actual installed Mihon client Pipeline acceptance

Build the independent entry with the existing production dependencies:

```sh
TMPDIR=/path/to/disk/tmp flutter build apk --profile --split-per-abi \
  --target test/device_acceptance/source_mihon_client_pipeline.dart
```

Run the same-certificate APK with its ordinary restore artifact:

```sh
python3 apps/app/test/device_acceptance/source_mihon_client_pipeline.py \
  --serial DEVICE_SERIAL --fixture-apk /path/to/fixture.apk \
  --restore-apk /path/to/ordinary.apk --out /path/to/evidence
```

The device must already have `eu.kanade.tachiyomi.extension.zh.wnacg` installed.
The fixture copies that immutable APK into its private temporary directory and
uses the real production Mihon activation, class loader, client and source.
It does not install an extension, register a source or open the user library.

The original resource loader must select the source client for a controlled
GET redirect. Every successful/cancelled transfer must actually invoke Mihon
`loadResource`; successful bodies must negotiate and release sealed-file-v1.
The HTTP server records synthetic explicit Cookie and User-Agent headers and
never sets cookies. Static and animated WebP use the previously sealed assets
in `fixtures/source_native_webp/`; their private copies are removed in finally.

Six cases cover native texture presentation and durable byte-exact READY,
new cold composition owners making no source/HTTP requests, and cancellation
during the source client's actual redirected body read for both media samples.
Cancellation must close the TCP peer and physical task without a claim, READY
or frame. Native prefix-growth waits remain separate from provider retries.
Actual frame advancement, owner shutdown, request/claim/release counts and
four screenshots are recorded; complete user backups must match before/after.

This is one installed WNACG1.6 client's controlled GET/request/redirect/body
evidence. It does not prove its real origin, all Mihon clients/ABIs, CookieJar
mutation, POST/interceptors, partial animated live streaming, original19/20
loading, allocation/GC/input latency or final physical display performance.
Existing Venera, body-lifetime and real-origin acceptances remain independent.

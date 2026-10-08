# Actual source-body native WebP Pipeline acceptance

Build the independent entry with the existing production dependencies:

```sh
TMPDIR=/path/to/disk/tmp flutter build apk --profile --split-per-abi \
  --target test/device_acceptance/source_native_webp_pipeline.dart
```

Run the companion runner with a same-certificate ordinary restore APK:

```sh
python3 apps/app/test/device_acceptance/source_native_webp_pipeline.py \
  --serial DEVICE_SERIAL --fixture-apk /path/to/fixture.apk \
  --restore-apk /path/to/ordinary.apk --out /path/to/evidence
```

The runner stages the sealed static and animated WebP assets privately through
`adb shell -T` stdin before launch, verifies their hashes and removes them
before restoring the APK. The remote shell command is quoted as one argument;
staging exit status alone is insufficient without the device hash check.
Assets and their exact metadata live in `fixtures/source_native_webp/`;
they are test inputs and do not enter the production asset manifest.

A temporary Venera source's canonical `onResponse` preserves the original
encoded WebP bytes. The actual HTTP/rhttp, source process, Service/Binder,
claimed file, DownloadSession and durable artifact owners remain unchanged.
Reader presentation must record native decode and Android texture output.
The four-frame animation must advance actual presented frames. Trace
observers return the original source responses without changing control,
retry, policy, playback clock or output ownership.
Unsealed WebP `decode-prefix` events may wait for a strictly larger encoded
prefix. These are reported separately from provider retries; all task failures
and other retry stages fail the acceptance.

Six cases cover first download, completely new composition/store/cache and
native media owners reopening exact READY with zero source requests, and
route teardown during held HTTP input for both static and animated samples.
Verified artifact bytes must equal the origin bytes and the claimed body
hash. Cancellation must close the actual TCP peer and physical task without
a body claim, READY or frame. All compositions/source/input files close.

The fixture only opens temporary stores. Compare complete user backups
before/after; the runner restores the ordinary APK in finally and retains
traces/screenshots. Previous PNG, resolver, Cookie/redirect and body-lifetime
fixtures stay independent and unchanged.

For the independent zero-frame transition case, build with
`--dart-define=ZIC_SOURCE_NATIVE_WEBP_TRANSITION_ONLY=true` and pass
`--transition-only` to the same runner. The server sends an incomplete animated
prefix on the current page and keeps actual TCP alive below one complete frame.
The neighbor predownloads through the ordinary source request plan and host
stream, with no whole-body transform. Fresh XML bounds locate the test-only
Reader semantics surface for an actual partial drag. The target must produce
its own first native frame while current remains at zero, then current must
recover its three-frame bootstrap before neighbor deep refill. Full forward
and reverse gestures must preserve both physical session objects and epochs
with only two origin requests. Test-owned server pacing never replaces a
production Future, scheduler, frame or playback clock. Already accepted six
file-body cases are skipped in this mode.

For cold partial hydration, use
`--dart-define=ZIC_SOURCE_NATIVE_WEBP_PARTIAL_ONLY=true` and `--partial-only`.
Only the staged test animation's ANMF durations change to600ms in memory;
the server publishes two complete frames with the remaining body unsealed.
Exact and contributed verified-equivalent misses must not create a session in
the durable store. Actual native presentation/DecodeSession looping precedes
physical teardown and TCP closure. New store/cache/transfer/native owners
then reopen the durable prefix; the second origin sends less than one frame,
so first-frame playback must use local hydration before network admission.
Both physical cancellations must preserve the exact, nonshrinking playable
prefix. EOF/mismatch variants, real origins and performance are separate.

For the independent partial error branches, use
`--dart-define=ZIC_SOURCE_NATIVE_WEBP_PARTIAL_FAILURES_ONLY=true` and
`--partial-failures-only`. A playable native prefix is staged once, then each
new composition uses an entityless source GET and receives an actual Range206
premature EOF, overlap mismatch,
HTTP200 catch-up premature EOF, or malformed network-only sidecar metadata.
An existing explicit-completion consumer forces the network attempt to finish;
it does not change Reader policy or the default NetLane. Attempt failures must
retire actual TCP/lane work while the old prefix keeps presenting, with no epoch
reset, source disable or durable byte loss. Corrupt network knowledge must be
discarded without invalidating body/owner/checkpoint proof. Complete HTTP200
CRC mismatch is intentionally excluded from these preserve-prefix cases:
current Spec permits a bounded clean-generation restart after that proof.
To run only the metadata branch, build with
`--dart-define=ZIC_SOURCE_NATIVE_WEBP_PARTIAL_METADATA_ONLY=true` and pass
`--partial-metadata-only`. Resolve the sidecar through the current durable index
after physical retirement; the departed warm spool is not its storage owner.

This proves selected canonical onResponse/file and ordinary streaming/native
WebP paths, including the selected unsealed-prefix transition and cold reentry.
It does not prove Mihon clients, real origins, every partial error branch,
Venera whole-input allocation/backpressure, every lifecycle/loop variant,
original19/20 intermittent loading or final physical display performance.

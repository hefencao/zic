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

The fixture only opens temporary stores. The runner restores the ordinary APK
in finally and overwrites the same purpose trace/results. Command output keeps
only its last4096 characters and original length, so raw trace/logcat are not
duplicated into command records. Remove completed captures after recording the
scoped conclusion. Previous PNG, resolver, Cookie/redirect and body-lifetime
fixtures stay independent and unchanged.
The runner reads only the actual fixture host/source PIDs and rejects their
uncaught exceptions even when Dart case assertions passed. Ordinary restoration
still completes before reporting this failure.

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

For different-provider cold partial, use
`--dart-define=ZIC_SOURCE_NATIVE_WEBP_CROSS_PROVIDER_PARTIAL_ONLY=true` and
`--cross-provider-partial-only`. Three native Reader entries use distinct
version/comic/chapter/page/revision/URI identities with test-contributed canonical
authority: A creates a playable prefix, completely new owners restore it for B,
then completely new owners restore B's extended checkpoint for A and promote
the exact complete body. Cold responses initially send only4096bytes; local
native frame0/partial looping must precede continuity. Each cold GET sends a
validatorless tail Range; exact206/total/64KiB byte overlap must preserve the
epoch and append without another HTTP open. Each actual response establishes
only its own URI's ETag. Canonical checkpoints may discard network acceleration;
this does not require cold persistence of every provider validator. An existing
explicit-completion consumer advances the held continuation after local first
frame, with unchanged scheduling/flow-control policy. Final bytes/CRC, physical
partial retirement, all three TCP peers and all temporary owners must pass.
Live-origin version declarations/mapping and final display performance remain
independent. Previously accepted exact-only cases are skipped.

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

For saturated transport/read capacity, use
`--dart-define=ZIC_SOURCE_NATIVE_WEBP_CAPACITY_ONLY=true` and `--capacity-only`.
The default coordinator admits five actual normal HTTP responses, queues the
sixth equal-ranked request, then admits it only after current promotion through
the one reserved handoff. Five native-proven playable responses park while
retaining demand and all six transport leases; only their read permits release.
The server supplies a bounded next chunk after current detaches, so the pending
socket read reaches the Spec's next safe read boundary before parking.
An independent cold durable Reader presents under this saturation with zero
origin requests, zero remote capacity and zero persistent-artifact session copies.
Current reacquisition must continue one existing TCP body/session/epoch/task key
without eviction, preemption or a second open; all six peers and owners close.
The resume input supplies128KiB, exceeding the unchanged64KiB commit quantum;
an uncommitted smaller chunk is not interpreted as stopped transport.
Server-only output pacing and native decode prove these facts without injecting
playable evidence or altering the production NetLane or budgets. This mode does
not prove a blocked retention-exit race, destructive preemption or historical
real-origin timing acceleration.

For shared physical transfer/exact durable authority, use
`--dart-define=ZIC_SOURCE_NATIVE_WEBP_ALIAS_ONLY=true` and `--alias-only`.
The existing production reader-scope consumer starts an actual source HTTP
response; the chapter service's B command must join it before releasing the
test-owned server output. Only B acquires required exact durable bytes, verified
against the complete origin; A gets no extra durable artifact or HTTP request.
The second case starts two actual demanded owners before contributing equivalence.
Late proof must preserve both owners; a fresh equivalent selects a preferred
promoted owner without a third request. The retired ambiguous-rejection/takeover
marker is not a current contract. Three TCP peers and all service/source owners
must exit. This tests physical/exact ownership with test-contributed byte
equivalence, without claiming Reader UI, native frames or real source-version
discovery. Previously accepted native/frame cases are skipped.

For the two remaining pressure branches, use
`--dart-define=ZIC_SOURCE_NATIVE_WEBP_PRESSURE_ONLY=true` and `--pressure-only`.
Six real source HTTP bodies saturate the unchanged default NetLane. A new
current must produce one typed body-read preemption and preserve the victim's
authoritative partial as idle without failure. Separately, two withdrawn
responses park; actual inactive-lease cancellation triggers a test-owned current
command for the surviving original response. Observe its read grant while the
cancelled physical task still owns its lease, then consume more original TCP
bytes without replacing its session, epoch or task. No production Future is
delayed, and trace callbacks only observe results. All13 peers and temporary
owners must close. Previously accepted capacity/native/READY cases are skipped.

This proves selected canonical onResponse/file and ordinary streaming/native
WebP paths, including the selected unsealed-prefix transition and cold reentry.
It does not prove Mihon clients, real origins, every partial error branch,
Venera whole-input allocation/backpressure, every lifecycle/loop variant,
original19/20 intermittent loading or final physical display performance.

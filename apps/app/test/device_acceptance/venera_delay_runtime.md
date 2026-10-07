# Android Venera delay runtime acceptance

Build the independent test entry using the current production dependencies:

```sh
TMPDIR=/path/to/disk/tmp flutter build apk --profile --split-per-abi \
  --target test/device_acceptance/venera_delay_runtime.dart
```

Run the companion runner with a same-certificate ordinary restore APK:

```sh
python3 apps/app/test/device_acceptance/venera_delay_runtime.py \
  --serial DEVICE_SERIAL --fixture-apk /path/to/fixture.apk \
  --restore-apk /path/to/ordinary.apk --out /path/to/evidence
```

Six cases cover normal delay, negative-duration normalization, two timers
under one requestId, scheduler cancellation of two long timers while a
foreign requestId timer remains pending, that peer's normal completion, and
a subsequent canonical invocation using the same source/runtime. The
source adapter retains its original single invocation gate, and every call
uses the production NetLane TaskControl. A loopback marker acknowledges
actual timer registration before the test cancels. The marker uses the
source's real Network.post bridge; it does not replace a production Future.

The temporary source uses the public sendMessage delay primitive. Its
explicit foreign requestId tests timer scoping within the same WebView,
without admitting another concurrent canonical source invocation. Read-only
bootstrap observations identify timer registration/retirement; they do not
mutate timers, request IDs, results or cancellation. Joined cancellation
must preserve ErrorCode.cancelled and complete within 500 ms. Normal timing
has an observation tolerance; it is not a device performance guarantee.

The fixture opens no user library, preferences or installed-source roster.
It uses a temporary source payload and closes its source runtime and marker
server. The runner retains the device result/logcat and restores the ordinary
APK in finally. Compare complete exported user backups before and after.

This scope closes only the selected Venera delay contract. It does not prove
all other source/client variants, source HTTP/DNS blocking-read cancellation,
priority preemption, original intermittent Reader loading, fixed-position
stutter, input latency or final physical display performance.

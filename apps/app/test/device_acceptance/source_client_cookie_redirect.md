# Actual Android source-client Cookie and redirect acceptance

Build the independent entry with the original production dependencies:

```sh
TMPDIR=/path/to/disk/tmp flutter build apk --profile --split-per-abi \
  --target test/device_acceptance/source_client_cookie_redirect.dart
```

Run the companion runner with a same-certificate ordinary restore APK:

```sh
python3 apps/app/test/device_acceptance/source_client_cookie_redirect.py \
  --serial DEVICE_SERIAL --fixture-apk /path/to/fixture.apk \
  --restore-apk /path/to/ordinary.apk --out /path/to/evidence
```

The temporary Venera source requests the network and cookies capabilities.
Its pages pass through the actual deferred source locator, source request
plan, host rhttp, source-process Android CookieManager/manual redirect/rhttp,
Service/Binder and original Reader Pipeline. Observers return the original
responses and errors and forward the same scheduler control.

Eight cases independently verify stateless streaming, 200 Set-Cookie
fallback, a subsequent source-owned CookieJar request, same-origin redirect
cookie continuity, cross-origin explicit Cookie/Authorization removal,
POST 303 conversion to GET, POST 307 method/body preservation, and route
teardown during an actual held redirected source-client TCP body. Successful
cases require exact origin bytes in durable READY and an actual PNG first
frame, without provider retry or a second resolve. Stable results and
cancelled work are observed for six seconds. Cancellation requires peer and
delegate exit before the composition completes and no READY or frame.

The fixture only opens temporary stores. It uses unique Cookie names and a
unique test path on two loopback origins, then expires only those cookies
through the original source client and audits both origins. It never opens
the user library, preferences or installed-source roster. The runner retains
trace/screenshots and restores the ordinary APK in finally. Compare full
user backups before/after.

An interrupted older run may supply only its task-owned cookie name/path
metadata through the test-only build define
`ZIC_SOURCE_CLIENT_FIXTURE_PREVIOUS_COOKIE_SCOPES` (JSON list of name/path
objects). The same source client expires those exact cookies and checks both
origins. This parameter is empty by default; cookie values and arbitrary
user-cookie names must never be supplied.

This scope verifies selected Venera full-byte fallback and stateless
streaming. It does not prove real external origins, Mihon CookieJar/client
wrappers, browser handoff/reset, all redirect/HTTP variants, native WebP,
live streaming/backpressure, production theme, original19/20 intermittent
loading or final physical display performance. Previous accepted fixtures
and production policies remain unchanged.

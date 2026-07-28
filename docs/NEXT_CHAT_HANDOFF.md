# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.21.1-dev.25_source-network-fix.zip`.
Do not merge or copy files from an earlier zic archive.

## Current implementation

- Home, Bookshelf and Comic Sources are the three primary destinations; remote browsing remains lazy.
- MangaDex browse/detail/feed/@Home requests use the catalog source boundary and existing Reader
  artifact path.
- Generated Android hosts are configured by `tool/configure_platforms.py`, which idempotently adds
  `android.permission.INTERNET` to the main application manifest.
- Bootstrap, Android build and `tool/run_android.sh` all enforce the host configuration.
- Source failures retain `Failure.cause` and stack traces and render complete selectable/copyable
  diagnostics. `Failed host lookup` receives a focused permission/system-DNS explanation.
- `HttpTransport` reports OS errno and uses a 15-second connection timeout. MangaDex metadata and
  artwork retry one transient network failure only.
- Reader double-tap regression uses two timed taps supported by the current Flutter test API.
- No IP pinning, certificate bypass, challenge solving, login/cookie import or anti-bot bypass exists.

## First local repair after updating an existing checkout

From the repository root:

```bash
python3 tool/configure_platforms.py
cd apps/app
flutter clean
flutter pub get
flutter run -d android
```

Or use the configured runner:

```bash
./tool/run_android.sh
```

Uninstall an already installed release APK before retesting if its manifest was built without the
Internet permission.

## Validation completed in this environment

```bash
python3 tool/check_repo.py
python3 tool/configure_platforms.py --app <temporary fixture app>  # twice; one permission only
bash -n tool/*.sh
python3 -m py_compile tool/*.py
```

Additional delivery checks validate Dart delimiter balance, test registration scope, JSON/YAML/TOML
parsing, package versions, archive cleanliness and a clean re-extraction. This container does not
contain Flutter, Dart, Cargo, Android SDK or Android NDK, so no claim is made that their tests or
builds ran here.

## Required external validation

```bash
flutter pub get
flutter test packages/reader/test/reader_navigation_test.dart
flutter test packages/catalog/test/mangadex_source_test.dart
flutter test apps/app/test/source_browser_test.dart
bash ./tool/test_dart.sh
bash ./tool/test_flutter.sh
bash ./tool/analyze.sh
bash ./tool/check_native_header.sh
bash ./tool/check_webp.sh
bash ./tool/test_rust.sh
bash ./tool/build_android_native.sh release
bash ./tool/build_android.sh release
```

After building, verify the merged release manifest contains:

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

## Next mainline work

1. Add source-specific typed settings for translation languages and data-saver mode.
2. Add source update ingestion and timestamps so Home updates derive from actual remote changes.
3. Add durable per-chapter offline downloads with cancel/retry and authoritative cover waterlines.
4. Evaluate native platform HTTP adapters for proxy/VPN parity without bypassing TLS or source policy.
5. Define a sandboxed Mihon/Keiyoushi adapter ABI, permissions and lifecycle before loading extensions.

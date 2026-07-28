# zic next-chat handoff

## Sole baseline

The sole input baseline for the next iteration is
`zic_v0.18.3-dev.21_local-media-boundary_UNVERIFIED.zip`. It contains the complete
`fixed.zip` overlay lineage and all Reader artifact, mixed-image folder and texture work;
do not reapply any older archive or patch.

Version remains `0.18.3-dev.21` / `0.18.3+21` and must not be called stable until the
external Flutter/Android gate passes.

## Current candidate changes

- Moves local image models, desktop directory scanning and platform dispatch out of
  `apps/app/lib` into `packages/local_media`; the App keeps only a compatibility export.
- Retains image MIME/name candidates when SAF header probing fails and validates them when
  opened; document reads try ordinary, asset and typed-asset resolver streams.
- Adds Android bridge protocol version 2 so a stale cached plugin fails with a clean-build
  instruction instead of returning an old empty-directory result.
- Adds `./tool/clean.sh`; all `tool/*.sh` files are executable and the clean target removes
  project Flutter/Dart, Gradle, Rust, CMake/libwebp and generated JNI caches.
- Replaces Android raw-path directory scanning with a dedicated SAF document-tree bridge.
- Recursively enumerates `DocumentsContract` children and reads both headers and selected
  pages through the persisted `content://` grant.
- Keeps each folder page's content URI as its explicit source identity and byte-loader
  contract, while retaining `XFile` only for compatibility.
- Uses magic-byte sniffing first, then provider MIME and filename only as candidate fallbacks;
  full validity remains owned by the real codec.
- Reports header-recognized and metadata-fallback counts from Android document-tree scans.
- Keeps the isolate-backed recursive filesystem scanner for desktop/other IO platforms.
- Fixes the empty-folder diagnostic wording expected by the product contract.
- Fixes native Android texture stretching with a source-ratio contain viewport; texture
  dimensions and telemetry are no longer treated as proof of correct visual geometry.
- Changes WebP folder recognition from strict first-chunk/container validation to a
  permissive RIFF/WEBP signature sniff, while retaining parser/codec validation at open.
- Recognizes real playable WebP bytes regardless of filename and tolerates metadata or
  unknown leading chunks.
- Reports scanned, signature-unrecognized and unreadable file counts independently.
- Drives generic-image ready/invalid state through the displayed `MemoryImage` stream;
  deterministic tests can inject a decode probe without weakening production behavior.
- Retains LiveCoordinator promoted-artifact Reader ingress and explicit native activation.

## Mandatory validation gate

Run from the repository root in the Flutter-equipped environment:

```bash
flutter pub get
flutter test apps/app/test/app_smoke_test.dart
flutter test apps/app/test/webp_preview_test.dart
flutter test apps/app/test/webp_demo_test.dart
flutter test packages/local_media/test/local_image_folder_test.dart
flutter test packages/local_media/test/local_image_signature_test.dart
flutter test apps/app/test/local_image_preview_test.dart
bash ./tool/test_dart.sh
bash ./tool/test_flutter.sh
bash ./tool/analyze.sh
bash ./tool/check_native_header.sh
bash ./tool/check_webp.sh
bash ./tool/test_rust.sh
bash ./tool/build_android_native.sh release
bash ./tool/build_android.sh debug
```

Also run Android device coverage for background/foreground surface recreation,
overlapping Reader pages, texture replacement, resize and engine detach. Only after
all applicable checks pass should the version be incremented and a stable archive be
created.

## Next mainline work

1. Validate SAF document-tree scanning, persisted reads and switching on multiple Android providers, plus the desktop fallback.
2. Persist imported image folders as local chapter/catalog records and feed those
   records into the production Reader session rather than a standalone folder screen.
3. Bind promoted ingress to DecodeRegistry/UploadRegistry without automatically enabling
   unsafe texture output.
4. Add Android lifecycle/device tests for surface loss/recreation and concurrent
   PageView overlap, including retained-frame redraw and detach races.
5. Add CBZ import without moving filesystem I/O into the Reader package.


Before validating Android plugin changes, run:

```bash
./tool/clean.sh
flutter pub get
./tool/build_android.sh debug
```

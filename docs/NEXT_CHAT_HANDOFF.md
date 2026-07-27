# zic next-chat handoff

## Baseline and candidate status

The only verified input baseline for this iteration is
`zic_v0.18.3-dev.21.zip`. The current working tree contains an unreleased
candidate built strictly from that archive. Do not call the candidate stable and
do not increment any version until the validation gate below passes in a
Flutter/Android-equipped environment.

## Candidate changes

- Picker, route navigation, WebP container validation, and preview page state are
  independent test boundaries.
- `PickedWebp(displayName, file)` remains the explicit product contract.
- Tests use semantic keys or `WebpPreviewState`, not helper text identity,
  fixed-duration pumping, or `XFile.fromData` name behavior.
- Android `SurfaceProducer` output, one serial blit lane, JNI frame retain/blit/
  release, current-frame redraw ownership, and detach-safe frame scheduling are
  implemented.
- Texture telemetry covers queue, upload, relative deadline miss, frame bytes,
  texture bytes, in-flight bytes, and fallback.
- Animated WebP is connected to a real `ReaderView` page through
  `ReaderPageBuilder`; the standalone preview remains a diagnostic entry.

## Mandatory validation gate

Run from the repository root:

```bash
flutter pub get
flutter test apps/app/test/app_smoke_test.dart
flutter test apps/app/test/webp_preview_test.dart
flutter test apps/app/test/webp_demo_test.dart
bash ./tool/test_dart.sh
bash ./tool/test_flutter.sh
bash ./tool/analyze.sh
bash ./tool/check_native_header.sh
bash ./tool/check_webp.sh
bash ./tool/test_rust.sh
bash ./tool/build_android_native.sh release
bash ./tool/build_android.sh debug
```

Also run Android lifecycle/device coverage for background/foreground surface
recreation, overlapping Reader pages, texture replacement, resize, and engine
detach. Only after all applicable checks pass should the version be incremented
and a new stable source archive be produced.

## Next mainline work after validation

1. Replace the demo-only `FakeCoordinator` upload path with the production
   decode/upload/present session path used by Reader demands.
2. Attribute decode, upload, present, fallback, and memory telemetry to
   session/decode identity and demand revision.
3. Add device tests for surface loss/recreation and concurrent PageView overlap.
4. Extend the real Reader media path to local chapter/CBZ import and persisted
   catalog entries.

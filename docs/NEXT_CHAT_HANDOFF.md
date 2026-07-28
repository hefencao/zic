# zic next-chat handoff

## Baseline and candidate status

The only verified input baseline for this iteration is
`zic_v0.18.3-dev.21.zip`. The current working tree contains an unreleased
candidate built strictly from that archive. Do not call the candidate stable and
do not increment any version until the validation gate below passes in a
Flutter/Android-equipped environment.

## Candidate changes

- The route timeout is repaired at the test boundary: route tests assert keyed
  destinations with `skipOffstage: false`; Reader media content is tested directly
  with an injected chapter and explicit `WebpPreviewState`.
- Static and bundled catalog tests use stable semantic keys rather than page copy.
- All WebP entry points default to Flutter codec. Reader/folder workflows hide native
  controls; standalone native startup requires selecting `Native（实验）` and confirming.
- Android frame scheduling is posted to the main handler; serial blit ownership,
  retained-current-frame redraw, release and telemetry contracts remain intact.
- The home screen now supports recursive local WebP folder import. Enumeration runs
  in a background isolate, filenames use explicit relative-path ownership, natural
  sorting is deterministic, and the folder screen creates only the current player
  while supporting previous/next/menu switching.
- Picker cancel, folder cancel, valid/malformed validation, preview state, Reader
  content, folder enumeration and WebP switching remain separate tests.

## Mandatory validation gate

Run from the repository root:

```bash
flutter pub get
flutter test apps/app/test/app_smoke_test.dart
flutter test apps/app/test/webp_preview_test.dart
flutter test apps/app/test/webp_demo_test.dart
flutter test apps/app/test/local_webp_folder_test.dart
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

1. Rerun the three target Flutter tests and the complete validation gate in the
   Flutter-equipped environment; do not version the candidate before they pass.
2. Replace the demo-only `FakeCoordinator` demand path with the production
   decode/upload/present session path used by Reader demands.
3. Add Android device tests for surface loss/recreation and concurrent PageView
   overlap, including retained-frame redraw and detach races.
4. Promote `PickedWebpFolder` into a persisted local chapter/catalog source, then
   add CBZ import without moving filesystem I/O into the Reader package.

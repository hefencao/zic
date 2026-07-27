# zic next-chat handoff

Use `zic_v0.18.3-dev.21.zip` as the only code baseline. Do not roll back to earlier packages or copy individual files from old releases.

## Required pre-handoff validation

Run these commands in the Flutter-equipped development environment before starting the next chat:

```bash
cd /home/unkloser/projects/zic
flutter pub get
cd apps/app
flutter test test/app_smoke_test.dart
cd ../..
bash ./tool/test_flutter.sh
bash ./tool/test_dart.sh
bash ./tool/analyze.sh
bash ./tool/check_webp.sh
cargo fmt --all -- --check
cargo test --workspace
```

The two local-import smoke cases must both pass, show the exact keyed titles `local.webp` and `broken.webp`, and expose malformed validation only through `webpPreviewErrorKey`.

## Current state

- The local picker returns `PickedWebp`, which owns both bytes/file access and a normalized display name; malformed validation uses a unique keyed detail while the footer reports only `加载失败`.
- Static 100-page reader, built-in Animated WebP previews, local WebP import, Flutter-codec fallback, Rust/libwebp decoding, finite/infinite loops, adaptive physical targets, source-aware raster plans, frame pacing, cache/session infrastructure, and independent scheduler lanes remain implemented.
- libwebp 1.6.0 is built from pinned upstream source for host and Android ABIs.

## Next implementation target

1. Android `SurfaceProducer` texture output backed by native decoded frames.
2. Serial native blit lane and explicit texture/frame ownership.
3. Runtime telemetry for decode, upload, present deadlines, memory, and fallback.
4. Connect the production media path to actual reader pages rather than the preview-only screen.
5. Preserve Flutter-image fallback and split-APK packaging.

# zic next-chat handoff

## Sole baseline

Continue from `zic_v0.18.3-dev.21_android-library-shell.zip`.

## Current implementation

- Android SAF mixed-image folder import persists local chapters and refreshes
  existing tree identities.
- Local folders run through LoaderTransport, DownloadSession, promoted artifact
  and Reader; reading page/mode are persisted.
- Home and Bookshelf are the two primary app destinations.
- Home has update and reading-history card rails plus retained media diagnostics.
- Bookshelf has custom categories, local/remote filtering, management deletion,
  recent/title/page-count/custom sorting and durable drag ordering.
- SQLite schema version 2 stores categories, per-comic shelf/liked/collected/
  category/custom-order preferences and explicit chapter read state.
- Cover cards can render animated memory images and expose a reusable download
  waterline with percent and page counts.
- Comic details implement liked/shelf/collected actions, category membership,
  chapter order reversal, read dimming and right-swipe restore unread.
- Metadata-free local comics open Reader directly on tap or long press.

## Validation commands

```bash
flutter pub get
flutter test packages/local_media/test/local_image_signature_test.dart
flutter test packages/local_media/test/local_image_folder_test.dart
flutter test packages/catalog/test/imported_library_store_test.dart
flutter test packages/storage/test/imported_library_store_test.dart
flutter test apps/app/test/app_smoke_test.dart
flutter test apps/app/test/library_ui_test.dart
bash ./tool/test_dart.sh
bash ./tool/test_flutter.sh
bash ./tool/analyze.sh
bash ./tool/check_native_header.sh
bash ./tool/check_webp.sh
bash ./tool/test_rust.sh
bash ./tool/build_android_native.sh release
bash ./tool/build_android.sh debug
```

## Next mainline work

1. Introduce a comic-level aggregate that groups multiple local/remote chapters
   under one cover and detail route.
2. Bind authoritative DownloadSession snapshots to cover waterline progress and
   expose per-chapter download commands.
3. Add remote catalog/update ingestion so Home update cards and the remote shelf
   filter use real source data.
4. Continue Android texture lifecycle/device testing and connect native output
   to Reader only after the safe fallback path remains intact.

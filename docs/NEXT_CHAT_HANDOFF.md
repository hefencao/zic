# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.20.0-dev.23_library-reader-controls.zip`.
Do not merge or copy files from an earlier zic archive.

## Current implementation

- Home omits the local-directory maintenance panel; folder import remains available and diagnostics
  are collapsed behind a secondary expansion section.
- Home update/history and Bookshelf gallery reuse the same exact-size `ComicCoverCard`.
- Bookshelf view selection is independent of sort selection. Custom order supports long-press cover
  dragging in gallery management mode and reorderable rows in list management mode.
- Management mode uses card tap for selection and exposes move, category membership, copy-info and
  confirmation-gated delete operations. The delete action is visually separated and destructive.
- A selected category can add one or more existing shelf comics. Category chips do not duplicate
  selection with checkmarks, and the Bookshelf has no duplicate inner title.
- Reader starts immersive with hidden controls. Tap toggles top/bottom overlays containing page
  slider/jump, pause, speed, rotation, favorite and chapter-cache commands.
- Reader supports pinch/pan and double-tap zoom, blocks page swiping while zoomed and resets zoom
  when navigating away.
- GIF and WebP playback control stays inside the existing player path. WebP retains download
  identity, telemetry, Flutter/native fallback and viewport-aware decode raster.
- “缓存本章” promotes all chapter pages in the current Reader workspace. It is session-scoped, not
  yet a durable offline download record.

## Validation completed in this environment

```bash
python3 tool/check_repo.py
# repository structure: OK
# demo pages: 100
# demo Animated WebP assets: 3
```

Additional delivery checks validate Dart delimiter balance, JSON parsing, shell syntax, version
consistency, archive cleanliness and a clean re-extraction of the final archive. This container does
not contain Flutter, Dart, Cargo, Android SDK or Android NDK, so no claim is made that their tests or
builds ran here.

## Required external validation

```bash
flutter pub get
flutter test apps/app/test/library_ui_test.dart
flutter test apps/app/test/reader_controls_test.dart
flutter test apps/app/test/app_smoke_test.dart
flutter test packages/reader/test/reader_navigation_test.dart
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

1. Replace the session-scoped Reader chapter cache with a durable application cache root and expose
   authoritative per-page/per-chapter snapshots to the catalog projection.
2. Bind aggregate download waterlines and cancel/retry commands to cover/details UI without giving
   widgets ownership of DownloadSession or artifacts.
3. Add remote catalog/update ingestion so Home updates and the remote shelf filter use real source
   records that join the same `LibraryComic` projection.
4. Run Android gesture/device tests for zoom versus page swiping, immersive system UI restoration,
   long-press drag behavior and native texture lifecycle.

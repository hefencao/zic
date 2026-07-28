# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.18.3-dev.21_local-library-progress.zip`; do not reapply older
archives or patches.

## Current implementation

- Android SAF directory import and mixed-image switching run through `local_media` and
  `local_media_bridge` rather than App-owned file I/O.
- Imported folders are serialized as `ImportedChapterRecord` and persisted through
  `ImportedLibraryStore`; the production backend is SQLite in the application-support
  directory, with an in-memory implementation for tests.
- The home page lists persisted local chapters, supports refresh/removal, and reopens them
  through `LoaderTransport -> DownloadSession -> promoted artifact -> Reader`. Android
  refresh reuses the persisted SAF tree URI; desktop refresh rescans the stored path.
- Reader page changes persist `ReadingProgress`; reopen restores the page and
  paged/continuous mode. Refresh follows the same page source across insertions/removals,
  stale writes are ignored, and a removed current page clamps to a valid index.
- `mediaFormat` is persisted per imported page so files with missing or misleading
  extensions reopen with the original detected format.
- PNG sniffing rejects bare/truncated container labels in both Dart and Android while full
  parser/codec validation remains authoritative.
- Reader artifact workspace and SQLite filesystem ownership remain below the App layer in
  `storage`/`storage_bridge`.

## Validation commands

Run from the repository root in a Flutter/Android-equipped environment:

```bash
flutter pub get
flutter test packages/local_media/test/local_image_signature_test.dart
flutter test packages/catalog/test/imported_library_store_test.dart
flutter test packages/storage/test/imported_library_store_test.dart
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

## Next mainline work

1. Bind promoted local/remote artifacts to real DecodeRegistry and UploadRegistry ownership,
   retaining the safe Flutter renderer as fallback.
2. Add Android lifecycle/device coverage for surface loss/recreation, overlapping Reader
   pages, retained-frame redraw, resize and engine detach races.
3. Add CBZ import through the local-media/catalog boundary without introducing filesystem
   I/O into Reader or App UI code.

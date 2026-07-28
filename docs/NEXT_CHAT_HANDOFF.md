# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.19.0-dev.22_comic-aggregate.zip`.
Do not merge or copy files from an earlier zic archive.

## Current implementation

- Android SAF mixed-image folder import persists and refreshes chapter identities.
- Imported pages still use LoaderTransport, DownloadSession, promoted artifacts and Reader.
- Home and Bookshelf project persisted chapter entries into catalog-owned `LibraryComic`
  aggregates keyed by `comicId`.
- `ImportedChapterRecord` persists backward-compatible `comicTitle` and `sequence` fields.
- One comic can expose multiple chapters under one cover, shelf preference and details route.
- Details sort chapters by sequence, retain per-chapter progress/read state, open the selected
  chapter, and reliably restore read chapters to unread through a non-destructive right swipe.
- Removing one grouped chapter preserves the comic preference until the last chapter is gone.
- Local directory maintenance remains per chapter so refresh/reconciliation ownership is clear.
- Directory refresh replaces the scanned page/source snapshot without losing aggregate title,
  chapter sequence or comic identity.
- Catalog and SQLite test registrations that had escaped `main()` are repaired.

## Validation completed in this environment

```bash
python3 tool/check_repo.py
# repository structure: OK
./tool/check_native_header.sh
# passed
```

Custom static checks also confirmed balanced Dart delimiters, valid JSON, shell syntax,
consistent versions and that no test registration starts at top-level. This container does
not contain `flutter`, `dart` or `cargo`. `tool/check.sh` reaches the pinned libwebp source
check, but outbound DNS prevents fetching the checkout, so no claim is made that toolchain,
libwebp source-build or Android build tests were executed here.

## Required external validation

```bash
flutter pub get
flutter test packages/catalog/test/imported_library_store_test.dart
flutter test packages/catalog/test/library_comic_test.dart
flutter test packages/storage/test/imported_library_store_test.dart
flutter test apps/app/test/library_ui_test.dart
flutter test apps/app/test/app_smoke_test.dart
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

1. Bind authoritative DownloadSession snapshots to comic/chapter download projections rather
   than passing presentation-only progress values into cover cards.
2. Expose per-chapter download commands and aggregate comic download waterlines without giving
   widgets ownership of sessions or artifacts.
3. Add remote catalog/update ingestion so Home updates and the remote shelf filter use real
   source records that naturally join the same `LibraryComic` projection.
4. Continue Android texture lifecycle/device testing; Reader native output remains gated by the
   existing Flutter-codec fallback contract.

# zic next-chat handoff

## Sole baseline

Continue only from `zic_v0.28.0-dev.32_test-harness-fix.zip`.
Do not merge or copy files from an earlier zic archive.

## Current implementation

- The product tree remains identical to `0.28.0-dev.32`; the follow-up archive only corrects widget/unit test timing, teardown gates and a race-sensitive queue assertion.
- Home, Bookshelf and Comic Sources remain the three primary destinations. Local and remote details retain
  separate state ownership while composing shared presentation and using exact `sourceId + comicId` routing.
- Management-mode covers own single-item delete/category migration. Long press enters source-composite batch
  selection; the batch surface owns batch move/copy/clear/delete and custom ordering uses a separate handle.
- Chapter tasks remain authoritative through `ChapterDownloadService`, `DownloadSession` and promoted artifacts.
  Covers and details subscribe to those snapshots, distinguish chapter and whole-comic projections, and clear
  active waterlines at terminal completion.
- `WholeComicDownloadQueue` now persists whole-comic jobs and policy to `whole_comic_queue.json`. It re-inspects
  chapter artifacts on restore, enforces global concurrency, coalesces active duplicate enqueue, and supports
  pause/resume/cancel/retry/remove without creating a second byte owner.
- Queue policy can require an unmetered network or charging. A policy loss cancels active chapter work through
  the existing chapter service, leaves resumable artifacts intact and moves the job to `waitingForPolicy`.
- The new `runtime_bridge` Android plugin reports validated connectivity, metered status and charging through
  versioned method/event channels. Unsupported hosts retain an explicit injectable fallback.
- Download Manager shows durable whole-comic jobs above per-chapter task/artifact state and exposes queue policy.
- Reader speed uses a centered bounded dialog. The exhaustive bookshelf sort label is restored, fixing the
  compilation failure reported against dev.31.
- SQLite remains schema 6 with source-composite library identity and retained/acknowledgeable migration evidence.

## Validation completed in this environment

```bash
python3 tool/check_repo.py
python3 tool/check_dart_structure.py
bash -n tool/*.sh
python3 -m py_compile tool/*.py
bash ./tool/check_native_header.sh
```

Additional delivery checks validate package versions, JSON/YAML/TOML syntax, Android plugin declarations,
archive cleanliness, source-baseline patch reproducibility and a clean re-extraction. This container does not
contain Flutter, Dart, Cargo, Gradle, Android SDK or Android NDK, so no claim is made that their builds/tests ran.

## Required external validation

```bash
flutter pub get
flutter test packages/runtime_bridge/test/runtime_bridge_test.dart
flutter test apps/app/test/whole_comic_downloads_test.dart
flutter test apps/app/test/chapter_downloads_test.dart
flutter test apps/app/test/library_ui_test.dart
flutter test apps/app/test/source_browser_test.dart
flutter test apps/app/test/reader_controls_test.dart
flutter test apps/app/test/app_smoke_test.dart
bash ./tool/test_dart.sh
bash ./tool/test_flutter.sh
bash ./tool/analyze.sh
bash ./tool/check_native_header.sh
bash ./tool/check_webp.sh
bash ./tool/test_rust.sh
bash ./tool/build_android_native.sh release
bash ./tool/build_android.sh release
```

## Next mainline work

1. Add side-by-side source-migration candidate comparison before confirmation, including cover, authors,
   chapter samples and explicit identity/risk differences.
2. Add source update ingestion and durable timestamps so Home updates reflect actual upstream changes.
3. Add source-specific typed settings for translation languages and data-saver mode.
4. Discover/manage orphaned offline artifacts without weakening DownloadSession ownership rules.
5. Define a sandboxed Mihon/Keiyoushi adapter ABI, permissions and lifecycle before loading extensions.

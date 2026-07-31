# zic next-chat handoff

## Sole baseline

Continue only from
`zic_v0.31.0-dev.61_reader-media-ui-decoupling-plugin-repository-layout.zip`.
It descends from the user-provided `zic_v0.31.0-dev.58_fixed.zip` through dev.59;
do not merge an earlier dev.58/dev.59 candidate.

## Completed in dev.61

- Mihon combined detail no longer treats an absent/empty embedded chapter property as
  final emptiness. It probes detailed/original manga candidates and compatible
  `getChapterList`/`fetchChapterList` APIs, continuing across empty and unsupported
  results. Only a fully empty normalized catalog synthesizes `正文`.
- Real Mihon chapters retain live `SChapter` identity in the runtime and use the
  existing restart-time exact re-resolution path.
- Venera `account` maps to `AuthenticatableComicSource`: credential login, ordered
  Cookie login, WebView snapshot login, logout and login state. Final URL, title,
  Cookie and localStorage are returned to the isolated runtime; Presentation does
  not own source account persistence.
- `_BootstrapApp` renders an in-memory usable composition immediately and opens
  durable services asynchronously. Home shows a top 2 px sync indicator instead of
  blocking on “正在恢复书架”.
- Reader scale 1 no longer installs a competing scale recognizer, so remote
  `PageView` swipe works. Static pages omit pause/speed controls.
- Remote WebP binds the native incremental cursor directly to the authoritative
  `DownloadSession.ingress.source`, waits on committed-byte advancement for
  `needMoreData`, and projects restored-prefix plus current-network progress in the
  top controls.
- Runtime worker tests now actually round-trip settings/account operations before
  asserting the complete protocol operation set.

- Reader composition moved to `packages/reader_runtime`; App uses a thin compatibility export and no longer has production dependencies on pipeline/session/storage/transport.
- Local image/WebP presentation moved to `packages/local_media_ui` and split into bounded files. WebP prefix parsing is imported explicitly from `media`.
- Mihon and Venera repository pages use left installed/right repository columns. The root source manager no longer duplicates installed plugins.
- Mihon language variants are grouped by package family; preferred/common entry is visible and alternatives are collapsed by default.

## Invariants

- Never synthesize one Mihon chapter until every compatible real chapter-catalog
  path has completed empty. Empty/unsupported from one candidate is not final.
- Do not serialize extension-private objects across Binder; retain live objects only
  in the isolated runtime and use bounded stable wire identities.
- Flutter may mediate Venera user input/WebView, but runtime owns validation,
  storage, login state and source callbacks.
- Durable library recovery must not block the first usable Home surface.
- At reader scale 1, page navigation owns horizontal drag. Static media does not
  expose animation controls.
- WebP streaming joins the existing DownloadSession/source/artifact pipeline; do
  not create a second downloader, partial-file watcher or Presentation cache.
- Preserve versioned Mihon ABI assets, read-only staging, isolated runtime process,
  payload verification, session/cancel/limits and Reader/download/cache ownership.

## Validation commands

```bash
python3 tool/check_repo.py
python3 tool/check_dart_structure.py
python3 tool/check_android_runtime_dependencies.py
python3 tool/test_android_runtime_dependencies.py
python3 tool/test_mihon_chapter_contract.py
python3 tool/test_mihon_abi_routing.py
python3 tool/test_mihon_classloader_contract.py
python3 tool/test_mihon_read_only_payload.py
python3 tool/test_mihon_entry_instantiation.py
python3 tool/test_mihon_payload_context.py
python3 tool/test_venera_bootstrap.py
python3 tool/test_venera_network_policy.py
python3 tool/test_venera_response_headers.py
python3 tool/test_external_login_bridge.py
python3 tool/test_external_source_settings_contract.py
python3 tool/test_reader_streaming_contract.py
python3 tool/test_ui_architecture_contract.py
python3 tool/test_configure_platforms.py
bash -n tool/*.sh
python3 -m py_compile tool/*.py
bash tool/check_native_header.sh

flutter pub get
(cd packages/plugin_host && dart test)
(cd packages/plugin_host_bridge && flutter test)
(cd apps/app && flutter test)
(cd apps/app/android && ./gradlew :plugin_host_bridge:testDebugUnitTest)
(cd apps/app/android && ./gradlew :app:checkReleaseDuplicateClasses :app:assembleRelease)
```

## Next mainline work

1. On device, verify one multi-chapter Mihon source opens two distinct chapter IDs
   and one true gallery source still receives the synthetic single chapter.
2. Exercise Venera credential, ordered-Cookie and WebView login against real sources,
   including logout and process restart persistence.
3. Verify remote page swipe before/after zoom and static/animated control visibility.
4. Test a large remote Animated WebP from empty and restored partial states; compare
   top-bar existing/new progress against DownloadSession snapshots and confirm native
   playback starts before final artifact promotion.
5. Profile asynchronous durable composition swap for state continuity and remove any
   remaining synchronous library/cache work from the first usable frame.

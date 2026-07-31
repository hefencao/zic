# zic next-chat handoff

## Sole baseline

Continue only from
`zic_v0.31.0-dev.64_misc-settings-compile-fix.zip`.
It is a direct modification of the user-provided
`zic_v0.31.0-dev.62_source-management-tabs-mihon-chapter-preflight.zip`;
do not merge an earlier candidate. `mihon-main.zip` and `vibevenera-master.zip`
were read-only compatibility references and are not part of the product tree.

## Completed in dev.64

- Fixed the `ChapterDownloadService` capability binding by explicitly casting
  to `ConfigurableChapterResourceLoader` after the runtime type check.
- Fixed the repository-model test callback to use `owners[sourceId]` instead of
  a nonexistent `Map.operator` getter.
- Added the fourth root destination, Misc, with quick settings, Settings,
  About, download/import shortcuts, and a bounded Debug trace projection.
- Added Data, Network, Bookshelf, Reading, Download, and Appearance settings.
  Executable settings delegate to the existing catalog store, cache
  coordinator, whole-comic queue, Reader composition, and theme owner.
- App preferences persist through injected `storage_bridge` map readers and
  writers. Presentation still does not import `dart:io` or own files.
- Library backup exports catalog metadata and progress through a user-selected
  destination. Directory roots remain read-only until an indexed migration and
  rollback protocol exists.

## Completed in dev.63

- Stable page identity is independent from delivery URI. A chapter may contain
  the same source locator more than once when its `pageId` values are distinct.
- Persistent downloads resolve `mihon:` and `venera-resource:` pages through an
  injected source loader selected inside `downloads`; plugin locators no longer
  fall through to `IoTransport`.
- Reader transfer notifications are coalesced and published after build instead
  of synchronously dirtying a `ValueListenableBuilder` during Widget build.
- Venera and Mihon page messages expose recognizable WebP/GIF/etc. hints while
  byte sniffing remains authoritative. Venera receives a browser UA by default.
- Venera redirects are host-managed, cookie-aware and limited to eight hops;
  both native HTTP paths disable their own automatic redirect behavior.
- Mihon covers are source-owned opaque resources with normalized absolute URLs
  and source headers, covering relative and header-dependent thumbnails.
- Mihon page count zero is progressively resolved from details with at most two
  concurrent cached chapter preflights. Rows and the aggregate total update in
  place; individual failures are visible.
- Empty/error chapter catalogs may attempt a synthetic gallery only when a real
  non-empty page list succeeds. If the page path also fails, the catalog failure
  remains in the diagnostic chain.

## Invariants

- Misc and Settings are projections and command surfaces, not new service
  owners. They cannot open plugin transports, read cookies, retain page bytes,
  or delete cache files outside `ResourceCacheCoordinator`.
- Storage-root changes remain unavailable until catalog indexes, plugin data,
  queue state, response bytes, and page artifacts can migrate atomically with
  rollback. Displaying and copying current paths is allowed.
- Debug trace capture is bounded and observational; disabling or clearing its
  UI projection does not change Reader/pipeline/download decisions.

- Presentation does not select transports, own page bytes, create page caches or
  branch on plugin URI schemes.
- `pageId` is the stable uniqueness key; URI/source locator is mutable and may
  repeat.
- Media hints never replace byte sniffing or decoder validation.
- Page-count preflight is bounded metadata work through the cached source; it is
  not Reader demand, download policy or page-byte retention.
- Synthetic Mihon chapters cannot hide a real failure unless the same source is
  proven to expose readable gallery pages.
- Retain versioned Mihon ABI assets, read-only staging, isolated runtime process,
  payload verification and Reader/download/cache ownership.

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
(cd packages/catalog && dart test)
(cd packages/downloads && dart test)
(cd packages/plugin_host && dart test)
(cd packages/plugin_host_bridge && flutter test)
(cd packages/reader_runtime && flutter test)
(cd apps/app && flutter test)
(cd apps/app/android && ./gradlew :plugin_host_bridge:testDebugUnitTest)
(cd apps/app/android && ./gradlew :app:checkReleaseDuplicateClasses :app:assembleRelease)
```

## Next mainline work

1. Run the full Flutter/Dart suite and Android release build to close the SDK
   validation gap for dev.64, including `misc_settings_test.dart`.
2. Define an atomic directory migration/rollback protocol before adding mutable
   data, download, cache, or plugin root selectors. Add backup import only after
   validating schema and collision behavior.
3. On a real Android device, verify Venera animated WebP playback through both a
   direct image URL and a deferred `onImageLoad` resource.
4. Verify JMComic/18comic accepts the synthetic gallery only when body pages load,
   and preserve the complete diagnostic when both chapter and page APIs fail.
5. Verify www.wn04.ru cover rendering, repeated-image chapters, Reader opening
   and persistent chapter download with source headers.
6. Measure page-count preflight on a large Mihon catalog; retain the two-worker
   bound and source-cache reuse unless trace data proves a different owner needs
   adjustment.
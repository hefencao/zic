# zic next-chat handoff

## Sole baseline

Continue only from
`zic_v0.31.0-dev.59_mihon-chapter-identity-venera-settings.zip`.
It is a direct descendant of the user-provided
`zic_v0.31.0-dev.58_fixed.zip`; do not merge either earlier dev.58 candidate.

## Completed in dev.59

- Mihon only synthesizes `正文` when the normalized upstream chapter catalog is
  empty. A non-empty catalog is preserved in full.
- Both 1.4 and 1.6 compatibility `HttpSource.fetchChapterList` implementations
  call `prepareNewChapter` for every returned chapter.
- The runtime retains live `SChapter` objects by opaque chapter ID. After a
  runtime restart it refreshes the catalog and matches URL first, then the
  bounded name/number/scanlator/date identity; missing or ambiguous chapters
  fail explicitly.
- Venera source `settings` now map to the shared `ConfigurableComicSource`
  protocol: switch, text/input, select, multi-select, and callback/action.
- Venera setting values are stored in the isolated runtime as typed JSON wire
  values. The dev.58 plain-string form is migrated for booleans and string
  arrays.
- Mihon and Venera settings both use the source-management settings entry.
  Venera has no Mihon login row. Source changes use the existing explicit
  apply/restart lifecycle.

## Invariants

- Never apply the gallery single-chapter fallback to a non-empty Mihon chapter
  list and never replace all chapter IDs with the manga URL.
- Do not serialize extension-private objects across Binder. Keep the live
  object only in the runtime; the wire identity remains bounded basic data.
- Keep source/plugin preference storage in the isolated runtime. Presentation
  only receives normalized setting records and sends normalized values.
- Preserve versioned Mihon ABI assets, Android 14 read-only staging,
  child/parent class-loader boundaries, payload verification, dedicated
  runtime process, session/cancel/limit ownership, and Reader/download/cache
  ownership.

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
python3 tool/test_configure_platforms.py
bash -n tool/*.sh
python3 -m py_compile tool/*.py
bash tool/check_native_header.sh

flutter pub get
(cd packages/plugin_host && dart test test/runtime_source_adapter_test.dart)
(cd packages/plugin_host_bridge && flutter test)
(cd apps/app && flutter test test/source_browser_test.dart)
(cd apps/app/android && ./gradlew :plugin_host_bridge:testDebugUnitTest \
  --tests dev.zic.pluginhost.MihonHostAbiTest)
(cd apps/app/android && ./gradlew :app:checkReleaseDuplicateClasses :app:assembleRelease)
```

## Next mainline work

1. Verify one real multi-chapter Mihon source: detail returns all chapters and
   opening two different chapter IDs produces different page lists.
2. Verify a gallery-style Mihon source whose real catalog is empty still opens
   the single synthetic chapter.
3. Exercise official Venera JM settings: switch/select persistence across
   restart and callback buttons such as refresh/check-in.
4. Add main-process UI mediation only if a Venera callback truly requires
   input/select dialogs; do not make the runtime service own Flutter UI.

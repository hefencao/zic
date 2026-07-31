# zic next-chat handoff

## Sole baseline

Continue only from
`zic_v0.31.0-dev.62_source-management-tabs-mihon-chapter-preflight.zip`.
It descends from the user-provided `zic_v0.31.0-dev.58_fixed.zip` through dev.59–dev.61;
do not merge an earlier candidate.

## Completed in dev.62

- Root source management classifies enabled sources into Native, Mihon and Venera
  sections with dividers.
- Mihon language variants are grouped in root source management, not in the APK
  repository. Preferred/current language remains visible; alternatives are
  collapsed by default.
- Mihon and Venera installation screens use top Installed/Repository tabs. Device
  Mihon discovery belongs to Installed and has a dedicated refresh/busy/error path.
- Durable source ordering remains available inside sections; a Mihon language
  family moves as one unit.
- Mihon chapter/page reflection supports inherited methods plus Future, RxJava 1
  blocking wrappers and RxJava 2/3 blocking terminals.
- A real chapter/page failure is no longer hidden by another empty candidate.
- Synthetic gallery chapters are exposed only after a non-empty page list is
  preflighted and therefore no longer appear as “single chapter, 0 pages”.
- Catalog-time remote page count zero is rendered as “页数待加载”.

## Invariants

- Installation records and enabled source instances are distinct projections.
- Language folding changes presentation only; it must not merge plugin/source
  identity, trust, settings, enablement or update state.
- Device extension scanning must not share repository loading state.
- Never synthesize a Mihon chapter to hide reflection, network or reactive-adapter
  failures.
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
(cd packages/plugin_host && dart test)
(cd packages/plugin_host_bridge && flutter test)
(cd apps/app && flutter test)
(cd apps/app/android && ./gradlew :plugin_host_bridge:testDebugUnitTest)
(cd apps/app/android && ./gradlew :app:checkReleaseDuplicateClasses :app:assembleRelease)
```

## Next mainline work

1. On device, verify a multi-chapter Mihon source exposes all chapters and each
   chapter resolves a distinct non-empty page list.
2. Verify a true gallery source receives one synthetic chapter with a non-zero
   page count, and that failures surface diagnostics instead of a placeholder.
3. Verify root source sections and default-collapsed Mihon language variants on a
   narrow Android screen, including durable reorder.
4. Verify Installed/Repository tab state, device refresh hit target and import
   flow for Mihon, and the corresponding Venera screen.

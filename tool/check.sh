#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUIRE_TOOLCHAINS=0
if [[ "${1:-}" == "--require-toolchains" ]]; then
  REQUIRE_TOOLCHAINS=1
fi

python3 "$ROOT/tool/check_repo.py"
python3 "$ROOT/tool/check_dart_structure.py"
python3 "$ROOT/tool/test_dart_library_directive_order.py"
python3 "$ROOT/tool/test_pipeline_runtime_compile_boundary.py"
python3 "$ROOT/tool/test_dev75_compile_ownership.py"
python3 "$ROOT/tool/test_dev76_reader_loading_ownership.py"
python3 "$ROOT/tool/test_dev77_atomic_media_ownership.py"
python3 "$ROOT/tool/test_dev78_reader_output_replay_diagnostics.py"
python3 "$ROOT/tool/test_dev79_stability_recovery.py"
python3 "$ROOT/tool/test_dev80_streaming_raster_trace_export.py"
python3 "$ROOT/tool/test_vertical_geometry_cover_trace_contract.py"
python3 "$ROOT/tool/check_android_runtime_dependencies.py"
python3 "$ROOT/tool/test_android_runtime_dependencies.py"
python3 "$ROOT/tool/test_android_trace_export_contract.py"
python3 "$ROOT/tool/test_venera_network_policy.py"
python3 "$ROOT/tool/test_venera_native_binary.py"
python3 "$ROOT/tool/test_mihon_entry_instantiation.py"
python3 "$ROOT/tool/test_mihon_payload_context.py"
python3 "$ROOT/tool/test_mihon_abi_routing.py"
python3 "$ROOT/tool/test_mihon_classloader_contract.py"
python3 "$ROOT/tool/test_mihon_read_only_payload.py"
python3 "$ROOT/tool/test_mihon_chapter_contract.py"
python3 "$ROOT/tool/test_venera_response_headers.py"
python3 "$ROOT/tool/test_venera_reader_preflight.py"
python3 "$ROOT/tool/test_source_resource_binding.py"
python3 "$ROOT/tool/test_reader_layout_settings_contract.py"
python3 "$ROOT/tool/test_pipeline_demand_stability.py"
python3 "$ROOT/tool/test_reader_streaming_contract.py"
python3 "$ROOT/tool/test_ui_architecture_contract.py"
python3 "$ROOT/tool/test_external_login_bridge.py"
python3 "$ROOT/tool/test_external_source_settings_contract.py"
if command -v node >/dev/null 2>&1; then
  python3 "$ROOT/tool/test_venera_bootstrap.py"
elif [[ "$REQUIRE_TOOLCHAINS" -eq 1 ]]; then
  echo "Node.js is required for the Venera bootstrap contract" >&2
  exit 1
else
  echo "SKIP: Node.js is not installed for the Venera bootstrap contract"
fi
"$ROOT/tool/check_native_header.sh"

SOURCE_TOOLS=(git cmake ninja)
MISSING_SOURCE=()
for command in "${SOURCE_TOOLS[@]}"; do
  command -v "$command" >/dev/null 2>&1 || MISSING_SOURCE+=("$command")
done
if ((${#MISSING_SOURCE[@]} == 0)); then
  "$ROOT/tool/check_webp.sh"
elif [[ "$REQUIRE_TOOLCHAINS" -eq 1 ]]; then
  echo "source-build tools are required: ${MISSING_SOURCE[*]}" >&2
  exit 1
else
  echo "SKIP: libwebp source-build tools are missing: ${MISSING_SOURCE[*]}"
fi

if command -v flutter >/dev/null 2>&1; then
  (cd "$ROOT" && flutter pub get)
  "$ROOT/tool/analyze.sh"
  "$ROOT/tool/test_dart.sh"
  "$ROOT/tool/test_flutter.sh"
  ZIC_ANDROID_NATIVE=0 "$ROOT/tool/build_android.sh" debug
elif [[ "$REQUIRE_TOOLCHAINS" -eq 1 ]]; then
  echo "Flutter SDK is required" >&2
  exit 1
else
  echo "SKIP: Flutter SDK is not installed"
fi

if command -v cargo >/dev/null 2>&1 && ((${#MISSING_SOURCE[@]} == 0)); then
  "$ROOT/tool/test_rust.sh"
elif [[ "$REQUIRE_TOOLCHAINS" -eq 1 ]]; then
  echo "Rust plus git/cmake/ninja are required" >&2
  exit 1
else
  echo "SKIP: Rust or source-build tools are not installed"
fi

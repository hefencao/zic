#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUIRE_TOOLCHAINS=0
if [[ "${1:-}" == "--require-toolchains" ]]; then
  REQUIRE_TOOLCHAINS=1
fi

python3 "$ROOT/tool/check_repo.py"
python3 "$ROOT/tool/check_documentation.py"
python3 "$ROOT/tool/check_dart_structure.py"
python3 "$ROOT/tool/test_dart_library_directive_order.py"
python3 "$ROOT/tool/test_pipeline_runtime_compile_boundary.py"
python3 "$ROOT/tool/test_dev75_compile_ownership.py"
python3 "$ROOT/tool/test_dev76_reader_loading_ownership.py"
python3 "$ROOT/tool/test_dev77_atomic_media_ownership.py"
python3 "$ROOT/tool/test_dev78_reader_output_replay_diagnostics.py"
python3 "$ROOT/tool/test_dev79_stability_recovery.py"
python3 "$ROOT/tool/test_dev80_streaming_raster_trace_export.py"
python3 "$ROOT/tool/test_dev81_route_stream_upload_test_stability.py"
python3 "$ROOT/tool/test_dev82_animation_trace_stability.py"
python3 "$ROOT/tool/test_dev83_preload_adaptive_stitch.py"
python3 "$ROOT/tool/test_dev84_mihon_transform_details.py"
python3 "$ROOT/tool/test_dev85_cloudflare_local_stream_contract.py"
python3 "$ROOT/tool/test_dev86_network_bridge_compile_ownership.py"
python3 "$ROOT/tool/test_dev87_cloudflare_metadata_artifact.py"
python3 "$ROOT/tool/test_dev88_source_browser_details_interaction.py"
python3 "$ROOT/tool/test_dev89_cookie_catalog_refresh_diagnostics.py"
python3 "$ROOT/tool/test_dev90_mihon_runtime_identity_alias.py"
python3 "$ROOT/tool/test_dev91_page_revisit_local_trace.py"
python3 "$ROOT/tool/test_dev92_static_finite_output_lifecycle.py"
python3 "$ROOT/tool/test_dev93_animation_successor_local_trace.py"
python3 "$ROOT/tool/test_dev94_vibe_webp_worker_pipeline.py"
python3 "$ROOT/tool/test_dev95_vibe_native_ingress_target_canvas.py"
python3 "$ROOT/tool/test_dev96_local_webp_playback.py"
python3 "$ROOT/tool/test_dev97_midpoint_trace_filter.py"
python3 "$ROOT/tool/test_dev98_libwebp_archive_prepare.py"
python3 "$ROOT/tool/test_dev99_frame_pipeline_timing.py"
python3 "$ROOT/tool/test_dev102_async_schedule_artifact_read.py"
python3 "$ROOT/tool/test_dev103_reader_reentry_platform_timing.py"
python3 "$ROOT/tool/test_dev104_startup_congestion_cursor_continuity.py"
python3 "$ROOT/tool/test_dev106_startup_ingress_pressure.py"
python3 "$ROOT/tool/test_dev107_reentry_progressive_handoff.py"
python3 "$ROOT/tool/test_dev109_cache_native_build_contract.py"
python3 "$ROOT/tool/test_dev110_staged_waterline_last_frame.py"
python3 "$ROOT/tool/test_dev111_decode_recovery_startup_pressure.py"
python3 "$ROOT/tool/test_dev112_ranked_download_adaptive_prefix.py"
python3 "$ROOT/tool/test_dev113_direct_cache_texture_pool.py"
python3 "$ROOT/tool/test_dev114_vertical_static_visibility_budget.py"
python3 "$ROOT/tool/test_dev115_empty_artifact_static_host_keepalive.py"
python3 "$ROOT/tool/test_dev116_runtime_webp_classification_compile.py"
python3 "$ROOT/tool/test_dev117_single_frame_webp_bootstrap.py"
python3 "$ROOT/tool/test_dev118_local_direct_visible_output.py"
python3 "$ROOT/tool/test_dev119_prefetch_wake_static_retention.py"
python3 "$ROOT/tool/test_dev120_directed_prefetch_source_wake.py"
python3 "$ROOT/tool/test_dev121_static_watermark_reader_rebuild.py"
python3 "$ROOT/tool/test_dev122_partial_loop_retained_download_vertical_ratio.py"
python3 "$ROOT/tool/test_dev123_download_preemption_vertical_composition.py"
python3 "$ROOT/tool/test_dev124_startup_current_prefix_patch_delivery.py"
python3 "$ROOT/tool/test_dev125_background_resume_retained_partial_failure.py"
python3 "$ROOT/tool/test_dev126_startup_playback_cadence.py"
python3 "$ROOT/tool/test_dev127_startup_buffer_refill_closure.py"
python3 "$ROOT/tool/test_dev128_native_decode_priority_migration.py"
python3 "$ROOT/tool/test_dev129_reader_background_reentry_vibe_lifecycle.py"
python3 "$ROOT/tool/test_dev130_retained_output_projector_compile_closure.py"
python3 "$ROOT/tool/test_dev131_load_starvation_playback_rebuffer.py"
python3 "$ROOT/tool/test_dev132_vibevenera_holder_playback_local_hot_bytes.py"
python3 "$ROOT/tool/test_dev133_vibevenera_reentry_direct_bytes_single_blit.py"
python3 "$ROOT/tool/test_dev134_reader_resource_session_retention.py"
python3 "$ROOT/tool/test_dev135_unified_version_cache_identity.py"
python3 "$ROOT/tool/test_dev136_catalog_weight_dead_code_compile.py"
python3 "$ROOT/tool/test_dev137_cover_primary_remote_flow_pressure.py"
python3 "$ROOT/tool/test_dev138_vibevenera_switch_independence.py"
python3 "$ROOT/tool/test_dev139_current_documentation.py"
python3 "$ROOT/tool/test_dev140_source_paging_mihon_language_equal_area_preview.py"
python3 "$ROOT/tool/check_test_quarantine.py"
python3 "$ROOT/tool/test_texture_schedule_timing_contract.py"
python3 "$ROOT/tool/test_texture_bridge_kotlin_compile.py"
python3 "$ROOT/tool/test_frame_pipeline_trace_analyzer.py"
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

SOURCE_TOOLS=(cmake ninja)
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
  echo "Rust plus cmake/ninja are required" >&2
  exit 1
else
  echo "SKIP: Rust or source-build tools are not installed"
fi

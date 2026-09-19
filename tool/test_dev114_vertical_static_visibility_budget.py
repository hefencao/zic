#!/usr/bin/env python3
"""Guard vertical visibility plus staged static presentation ownership."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.114 contract: {token}")

reader = read("packages/reader/lib/src/reader_view.dart")
geometry = read("packages/reader/lib/src/vertical_reader_geometry.dart")
window = read("packages/pipeline/lib/src/role_window.dart")
policy = read("packages/pipeline/lib/src/heuristic_policy.dart")
refill = read("packages/sessions/lib/src/decode_refill_policy.dart")
coordinator = read("packages/sessions/lib/src/live_coordinator.dart")
output = read("packages/pipeline_runtime/lib/src/pipeline_page_output.dart")
player = read("packages/local_media_ui/lib/src/local_image_player.dart")
memory = read("apps/app/lib/presentation_memory_policy.dart")
runtime = read("packages/pipeline_runtime/lib/src/pipeline_reader_session.dart")
check = read("tool/check.sh")

for token in (
    "visibleCoverages(",
    "viewportStart",
    "viewportEnd",
):
    require(geometry, token, "vertical viewport geometry")
for token in (
    "_lastVerticalTravelDirection",
    "_verticalTargetCoverage(",
    "targetCoverageOverride",
    "_verticalCacheScreens = 2",
):
    require(reader, token, "vertical Reader observation")
for token in (
    "observation.direction == ReadingDirection.vertical",
    "target.fraction > 0",
):
    require(window, token, "vertical transition role")
for token in (
    "_staticWarmPages(",
    "heuristic:static-warm",
    "targetWatermark: decodeWatermark",
    "StagedDecodeRefillPolicy releases one-frame work in priority",
):
    require(policy, token, "static one-frame intent policy")
for token in (
    "entry.value.targetWatermark == 1",
    "DecodeWaterlineStage.oneFrame",
):
    require(refill, token, "staged one-frame refill")
for token in (
    "_externalPresentationPending.add(id)",
    "onExternalPresentationRequested",
    "maxSpeculativeExternalPresentationPending = 1",
):
    require(coordinator, token, "external fallback presentation owner")
for token in (
    "externalPresentationRequested",
    "externalPresentationReady",
):
    require(output, token, "Pipeline external presentation projection")
for token in (
    "_maybeStartExternalPresentationLoad(output)",
    "output.externalPresentationRequested",
    "output.externalPresentationReady",
    "output.externalPresentationCacheIdentity",
    "_externalPresentationLoadIdentity",
    "identical(",
):
    require(player, token, "LocalImagePlayer generation-scoped external presentation gate")
require(
    read("packages/local_media_ui/test/external_presentation_generation_test.dart"),
    "mounted external static reloads when Pipeline presentation generation changes",
    "generation-scoped external presentation regression",
)
for token in (
    "zicFlutterImageCacheMaximumBytes = 100 * 1024 * 1024",
    "zicFlutterImageCacheMaximumEntries = 1000",
):
    require(memory, token, "Flutter fallback raster memory owner")
for token in (
    "_media is PipelineOutputPrewarmer",
    "_media as PipelineOutputPrewarmer",
    "_profile.speculativeExternalPresentationConcurrency",
):
    require(runtime, token, "compile-safe output prewarm capability")
require(
    read("packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart"),
    "speculativeExternalPresentationConcurrency: 3",
    "Reader bounded external-static first-frame concurrency",
)
for path, token in (
    (
        "packages/reader/test/vertical_reader_geometry_test.dart",
        "visible coverage reports adjacent pages before center handoff",
    ),
    (
        "packages/pipeline/test/pipeline_test.dart",
        "vertical overlap becomes transition before midpoint",
    ),
    (
        "packages/pipeline/test/pipeline_test.dart",
        "static neighbor outputs keep one-frame intents across the encoded window",
    ),
    (
        "packages/sessions/test/live_coordinator_test.dart",
        "external fallback presentation releases one speculative page at a time",
    ),
    (
        "apps/app/test/presentation_memory_policy_test.dart",
        "Flutter presentation raster cache has an explicit zic budget",
    ),
):
    require(read(path), token, path)
require(check, "test_dev114_vertical_static_visibility_budget.py", "repository check")
print("dev.114 vertical visibility/staged static presentation contract: OK")

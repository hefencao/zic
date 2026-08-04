#!/usr/bin/env python3
"""Guard dev.114 vertical visibility demand and memory-budgeted static outputs."""
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
    "const cacheScreens = 4",
):
    require(reader, token, "vertical Reader observation")
for token in (
    "observation.direction == ReadingDirection.vertical",
    "target.fraction > 0",
):
    require(window, token, "vertical transition role")
for token in (
    "staticOutputBudgetBytes = 96 * 1024 * 1024",
    "_staticWarmPages(",
    "heuristic:static-warm",
    "targetWatermark: decodeWatermark",
):
    require(policy, token, "memory-budgeted static predecode")
for token in (
    "_media is PipelineOutputPrewarmer",
    "_media as PipelineOutputPrewarmer",
):
    require(runtime, token, "compile-safe output prewarm capability")
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
        "static neighbor outputs fill the byte budget and remain evictable",
    ),
):
    require(read(path), token, path)
require(check, "test_dev114_vertical_static_visibility_budget.py", "repository check")
print("dev.114 vertical visibility/static budget contract: OK")

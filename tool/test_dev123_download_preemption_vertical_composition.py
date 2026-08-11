#!/usr/bin/env python3
"""Guard dev.123 active-rank download handoff and vertical composition reuse."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.123 contract: {token}")


lane = read("packages/sessions/lib/src/net_lane.dart")
coordinator = read("packages/sessions/lib/src/live_coordinator.dart")
transfer_owner_path = ROOT / "packages/sessions/lib/src/download_transfer_owner.dart"
physical_owner = (transfer_owner_path.read_text(encoding="utf-8")
                  if transfer_owner_path.exists() else coordinator)
composition = read("packages/pipeline_runtime/lib/src/pipeline_reader_session.dart")
lane_test = read("packages/sessions/test/net_lane_test.dart")
reader = read("packages/reader/lib/src/reader_view.dart")
geometry = read("packages/reader/lib/src/vertical_reader_geometry.dart")
reader_test = read("packages/reader/test/reader_navigation_test.dart")
geometry_test = read("packages/reader/test/vertical_reader_geometry_test.dart")
analyzer = read("tool/analyze_frame_pipeline_trace.py")
check = read("tool/check.sh")

for token in (
    "reservedHighPrioritySlots = 0",
    "highPriorityThreshold = 1000",
    "bool updatePriority(String key, int priority)",
    "activeTask.priority = priority",
    "_preemptLowestRunningFor(next)",
    "maxActive + reservedHighPrioritySlots",
):
    require(lane, token, "network lane priority migration")
for token in (
    "reservedHighPrioritySlots: 1",
    "highPriorityThreshold: 1000",
    "preemptionThreshold: 40",
):
    require(composition, token, "Pipeline network handoff composition")
for token in (
    "'demand-role'",
    "_migrateDownloadPriority(",
    "reason: 'retained-background'",
    "TraceEventKind.downloadPriorityChanged",
    "'handoffActive': net.handoffActive",
    "'effectivePriority': net.priorityOf(taskKey)",
):
    require(physical_owner, token, "download plan migration")
for token in (
    "active same-key promotion updates rank without restarting transfer",
    "current uses one handoff slot and preempts the lowest ranked transfer",
    "current preempts inside a full source bucket before global saturation",
    "handoff capacity stays bounded while cancellation unwinds",
):
    require(lane_test, token, "network lane owner tests")
for token in (
    "late List<Widget> _pageSlots",
    "List<Widget> _createPageSlots()",
    "_verticalCacheScreens = 2",
    "_verticalCacheScreens >= 7",
    "addSemanticIndexes: false",
):
    require(reader, token, "vertical Reader composition")
for token in (
    "late final List<double> _extents",
    "late final List<double> _starts",
    "int _indexAt(double offset)",
):
    require(geometry, token, "vertical geometry snapshot")
require(
    reader_test,
    "ratio updates reuse precomposed page shells instead of rebuilding content",
    "Reader composition owner test",
)
require(
    geometry_test,
    "layout snapshot computes page extents once and reuses prefix bounds",
    "geometry snapshot owner test",
)
for token in (
    "rankedDownloadMaxHandoffActive",
    "rankedDownloadPriorityMigrationCount",
):
    require(analyzer, token, "download trace analyzer")
require(check, "test_dev123_download_preemption_vertical_composition.py", "repository check")

if lane.count("final class _ActiveTask") != 1:
    raise SystemExit("active network task ownership is duplicated")
if "PageRole.visible" in read("packages/pipeline/lib/src/role_window.dart"):
    raise SystemExit("dev.123 must not reintroduce visible-page demand")

print("dev.123 download preemption/vertical composition contract: OK")

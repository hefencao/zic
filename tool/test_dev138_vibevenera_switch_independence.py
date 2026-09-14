#!/usr/bin/env python3
"""Guard VibeVenera-aligned target-page independence in dev.138."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.138 contract: {token}")


job = read("packages/sessions/lib/src/download_job.dart")
coordinator = read("packages/sessions/lib/src/live_coordinator.dart")
net_lane = read("packages/sessions/lib/src/net_lane.dart")
policy = read("packages/sessions/lib/src/decode_refill_policy.dart")
policy_test = read("packages/sessions/test/decode_refill_policy_test.dart")
reader = read("packages/reader/lib/src/reader_view.dart")
roles = read("packages/pipeline/lib/src/role_window.dart")
session = read("packages/pipeline_runtime/lib/src/pipeline_reader_session.dart")
profile = read("packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart")
trace = read("packages/telemetry/lib/src/trace.dart")
check = read("tool/check.sh")

for production in (job, coordinator, net_lane, trace):
    for forbidden in (
        "DownloadFlowGate",
        "beforeReadChunk",
        "downloadFlowPressure",
        "_refreshDownloadFlowPressure",
    ):
        if forbidden in production:
            raise SystemExit(f"target-page transport is still globally gated: {forbidden}")

for token in (
    "reservedHighPrioritySlots: 1",
    "highPriorityThreshold: 1000",
    "preemptionThreshold: 40",
):
    require(session, token, "NetLane current protection")

for token in (
    "stage: DecodeWaterlineStage.transitionFirstFrame",
    "targetWatermark: 1",
    "transitionFirstFrameDecision",
):
    require(policy, token, "transition first-frame refill")
if policy.index("if (transitionFirstFrameDecision != null)") > policy.index(
    "if (oneFrameDecision == null) return stagedDecision"
):
    raise SystemExit("transition first frame must resolve before staged current deepening")
for token in (
    "ready current bootstrap outranks transition first frame",
    "transition may bootstrap while current is waiting for source",
    "current deepening resumes after transition has its first frame",
):
    require(policy_test, token, "decode refill owner tests")

require(reader, "const PageScrollPhysics()", "Reader page switching")
require(
    roles,
    "this.transitionThreshold = defaultTransitionCoverageThreshold",
    "early transition promotion",
)
require(
    read("packages/pipeline/lib/src/coverage_thresholds.dart"),
    "const double defaultTransitionCoverageThreshold = 0.15;",
    "early transition threshold",
)
for token in (
    "forwardEncodedPages: 7",
    "backwardEncodedPages: 3",
    "networkConcurrency: 5",
    "decodeConcurrency: 3",
    "uploadConcurrency: 2",
    "remoteSourceConcurrency: 5",
):
    require(profile, token, "stable Vibe-derived profile")
require(check, "test_dev138_vibevenera_switch_independence.py", "repository check")

print("dev.138 VibeVenera target-page independence contract: OK")

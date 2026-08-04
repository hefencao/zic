#!/usr/bin/env python3
"""Guard dev.112 ranked page transfers and partial WebP prefix learning."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.112 contract: {token}")


net = read("packages/sessions/lib/src/net_lane.dart")
coordinator = read("packages/sessions/lib/src/live_coordinator.dart")
profile = read("packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart")
session = read("packages/pipeline_runtime/lib/src/pipeline_reader_session.dart")
policy = read("packages/pipeline/lib/src/heuristic_policy.dart")
scheduler = read("packages/downloads/lib/src/artifact_cache_read_scheduler.dart")
decode = read("packages/sessions/lib/src/decode_session.dart")
hints = read("packages/sessions/lib/src/webp_decode_prefix_hints.dart")
analyzer = read("tool/analyze_frame_pipeline_trace.py")
check = read("tool/check.sh")

for token in (
    "submitRanked",
    "bucketLimit",
    "activeForBucket",
    "idleKeys",
):
    require(net, token, "global ranked download lane")
for token in (
    "NetLane? pageDownloadLane",
    "pageDownloadLane: pageDownloadLane",
    "downloadBucketFor: _profile.downloadBucket",
    "downloadBucketLimitFor: _profile.downloadBucketLimit",
    "decode.depth > 4",
):
    require(session, token, "pipeline composition")
for token in (
    "networkConcurrency: 5",
    "localSourceConcurrency:",
    "remoteSourceConcurrency: 5",
    "remote:${id.content.sourceId}",
):
    require(profile, token, "source concurrency profile")
for token in (
    "net.submitRanked",
    "net.cancel(taskKey)",
    "net.idleKeys(networkKeys)",
    "TraceEventKind.downloadStarted",
    "'globalActive': net.active",
):
    require(coordinator, token, "ranked download coordination")
for token in (
    "PageRole.next => 820",
    "PageRole.next2 => 800",
    "PageRole.previous => 780",
    "_distanceDownloadPriority",
):
    require(policy, token, "per-page download rank")
if "startupBackgroundPriorityFloor" in scheduler or "startupBackgroundPriorityFloor" in session:
    raise SystemExit("startup priority floor must not replace page rank scheduling")
for token in (
    "class WebpDecodePrefixHints",
    "localWebpDecodePrefixQuantumBytes",
    "remoteWebpDecodePrefixQuantumBytes",
    "recordNeedMoreData",
    "recordSuccess",
):
    require(hints, token, "WebP prefix hints")
for token in (
    "if (!source.sealed)",
    "prefixHints.minimumBytes",
    "prefixHints.recordNeedMoreData",
    "'stage': 'decode-prefix'",
    "'failureClass'",
):
    require(decode if token != "'failureClass'" else coordinator, token,
            "partial decode classification")
if decode.count("bool advanceFrame(") != 0:
    raise SystemExit("decode session unexpectedly declares coordinator methods")
if coordinator.count("bool advanceFrame(") != 1:
    raise SystemExit("LiveCoordinator must declare advanceFrame exactly once")
for token in (
    '"decodePrefixHintCount"',
    '"rankedDownloadCount"',
    '"rankedDownloadMaxGlobalActive"',
):
    require(analyzer, token, "trace analyzer")
for path, token in (
    ("packages/sessions/test/net_lane_test.dart",
     "ranked page work enforces global and per-source limits"),
    ("packages/sessions/test/net_lane_test.dart",
     "idleKeys ignores work owned by another Reader"),
    ("packages/sessions/test/decode_session_test.dart",
     "partial WebP retries only after the learned per-frame prefix"),
    ("packages/pipeline/test/pipeline_test.dart",
     "expect(downloadPriorities.values.toSet(), hasLength(11))"),
):
    require(read(path), token, path)
require(check, "test_dev112_ranked_download_adaptive_prefix.py", "repository check")
for path in (
    "docs/adr/0096-ranked-page-download-adaptive-webp-prefix.md",
    "docs/audits/dev112-ranked-download-adaptive-prefix-audit.md",
    "docs/audits/dev112-validation-results.md",
):
    if not (ROOT / path).is_file():
        raise SystemExit(f"dev.112 evidence is missing: {path}")
print("dev.112 ranked download and adaptive WebP prefix contract: OK")

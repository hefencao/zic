#!/usr/bin/env python3
"""Guard dev.122 watermarks, partial-prefix loops, retained transfers and ratio isolation."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.122 contract: {token}")


policy = read("packages/pipeline/lib/src/heuristic_policy.dart")
guard = read("packages/pipeline/lib/src/policy_guard.dart")
refill = read("packages/sessions/lib/src/decode_refill_policy.dart")
decode = read("packages/sessions/lib/src/decode_session.dart")
coordinator = read("packages/sessions/lib/src/live_coordinator.dart")
transfer_owner = read("packages/sessions/lib/src/download_transfer_owner.dart")
screen = read("packages/reader_runtime/lib/src/reader_runtime_screen.dart")
reader = read("packages/reader/lib/src/reader_view.dart")
decode_test = read("packages/sessions/test/decode_session_test.dart")
coordinator_test = read("packages/sessions/test/live_coordinator_test.dart")
analyzer = read("tool/analyze_frame_pipeline_trace.py")
check = read("tool/check.sh")

for token in (
    "PageRole.current => 7",
    "PageRole.transition => 5",
    "PageRole.next => decodeWarmPages ? 5 : 0",
    "PageRole.next2 => decodeWarmPages ? 3 : 0",
    "PageRole.previous => decodeWarmPages ? 2 : 0",
):
    require(policy, token, "7/5/3/2 pipeline watermarks")
require(guard, "this.maxFrameWatermark = 7", "watermark guard")
for token in (
    "DecodeWaterlineStage.currentBootstrap",
    "DecodeWaterlineStage.currentMid",
    "DecodeWaterlineStage.currentDeep",
    "DecodeWaterlineStage.nextMax",
):
    require(refill, token, "7/5/3/2 staged refill")
for token in (
    "this.partialLoopMinFrames = 30",
    "_maxDecodedPrefixFrames >= partialLoopMinFrames",
    "'partialPrefix': true",
    "_restartPartialPrefix(source, epoch)",
):
    require(decode, token, "partial WebP prefix playback")
for token in (
    "net.cancelQueued(taskKey)",
    "session.state == DownloadState.promoted",
    "net.updateDemanded(taskKey, false);",
    "reason: 'inactive-physical-retention'",
    "net.cancel(key);",
    "net.idleKeys(keys)",
    "_downloadRetryPending.contains(id)",
    "'stage': 'download-recovery'",
):
    require(transfer_owner, token, "retained and deduplicated download ownership")
for token in (
    "ValueNotifier<Map<String, double>> _pageAspectRatios",
    "relativeDifference < 0.01",
    "pageAspectRatiosListenable: _pageAspectRatios",
):
    require(screen, token, "localized ratio updates")
if "ValueListenableBuilder<Map<String, double>>" in screen:
    raise SystemExit("runtime ratio updates must not rebuild the outer Reader screen")
for token in (
    "widget.pageAspectRatiosListenable?.addListener(_handlePageAspectRatiosChanged)",
    "void _handlePageAspectRatiosChanged()",
    "full PageView rebuild would amplify one media-header observation",
):
    require(reader, token, "ReaderView-owned live ratio updates")
require(reader, ".abs() > 2.0", "stable vertical anchor threshold")
require(decode_test, "cycles a thirty-frame partial prefix", "partial loop owner test")
require(
    coordinator_test,
    "active nonresumable transfer survives window detach and is not reopened",
    "retained transfer owner test",
)
for token in ("partialPrefixLoopCount", "downloadRecoveryCount"):
    require(analyzer, token, "trace analyzer")
require(check, "test_dev122_partial_loop_retained_download_vertical_ratio.py", "repository check")

if decode.count("void reset(SourceEpoch epoch)") != 1:
    raise SystemExit("DecodeSession reset declaration is duplicated")

print("dev.122 partial-loop/retained-download/vertical-ratio contract: OK")

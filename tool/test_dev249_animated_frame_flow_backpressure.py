#!/usr/bin/env python3
"""Guard dev.249 full-3/7 animated frame-flow backpressure ownership."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.249 contract: {missing}')

def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    if present:
        raise SystemExit(f'{path} contains superseded dev.249 shape: {present}')

pubspec = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
if m is None or int(m.group(1)) < 249:
    raise SystemExit('App build must be >=249')
build = int(m.group(1))
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')

require(
    'packages/pipeline/lib/src/animated_prefetch_policy.dart',
    'targetFramesByIndex',
    'if (readDistance == 1) return 5;',
    'if (readDistance == 2) return 3;',
    'if (readDistance == -1) return 2;',
)
reject(
    'packages/pipeline/lib/src/animated_prefetch_policy.dart',
    'DecodeWaterlineStage.currentMid =>',
    'DecodeWaterlineStage.nextMid =>',
    'DecodeWaterlineStage.currentDeep =>',
    'DecodeWaterlineStage.nextDeep =>',
)
require(
    'packages/pipeline/lib/src/heuristic_policy.dart',
    'flowTargetFrames: downloadFlow?.targetFramesFor(entry.key) ?? 0',
)
require('packages/pipeline/lib/src/demand.dart', 'flowTargetFrames')
require('packages/sessions/lib/src/download_transfer_owner.dart', 'flowTargetFrames', 'net.updateFlowTargetFrames')
if build >= 268:
    require(
        'packages/sessions/lib/src/net_lane.dart',
        'flowTargetFrames',
        'updateFlowTargetFrames',
        'releaseResponseReadPermit',
        'acquireResponseReadPermit',
    )
else:
    require(
        'packages/sessions/lib/src/net_lane.dart',
        'flowTargetFrames',
        'waitForFlowCredit',
        'updateFlowTargetFrames',
    )
reject(
    'packages/sessions/lib/src/net_lane.dart',
    'speculativeActiveBytes',
    'estimatedTransferBytes',
    'speculativeBudgetBytes',
    '_speculativeBudgetAvailable',
)
require(
    'packages/sessions/lib/src/webp_frame_prefix_tracker.dart',
    'class WebpFramePrefixTracker',
    "'ANMF'",
    'completedFrames',
)
if build >= 251:
    require(
        'packages/sessions/lib/src/download_job.dart',
        'response.flowControl != ByteResponseFlowControl.none',
        'waitBeforeRead',
        'addAuthoritativeBytes',
        "? 'paused'",
        ": 'pseudo-paused'",
        "? 'resumed'",
        ": 'pseudo-resumed'",
    )
    require(
        'packages/transport/lib/src/transport.dart',
        'enum ByteResponseFlowControl',
        'consumerPacing',
        'streamBackpressure',
    )
else:
    require(
        'packages/sessions/lib/src/download_job.dart',
        'ByteResponseFlowControl.streamBackpressure',
        'waitBeforeRead',
        'addAuthoritativeBytes',
        "action: 'paused'",
        "action: 'resumed'",
    )
    require(
        'packages/transport/lib/src/transport.dart',
        'enum ByteResponseFlowControl',
        'streamBackpressure',
    )
require('packages/transport/lib/src/io_transport.dart', 'ByteResponseFlowControl.streamBackpressure')
require('packages/downloads/lib/src/source_resource_transport.dart', 'ByteResponseFlowControl.streamBackpressure')
if build >= 252:
    require('packages/downloads_bridge/lib/src/rhttp_source_resource_transport.dart', 'ByteResponseFlowControl.consumerPacing')
else:
    require('packages/downloads_bridge/lib/src/rhttp_source_resource_transport.dart', 'ByteResponseFlowControl.streamBackpressure')
reject(
    'apps/app/lib/app_preferences.dart',
    '_animatedWebpPrefetchBudgetMiB',
    'setAnimatedWebpPrefetchBudgetMiB',
)
reject(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    'animatedPrefetchBudgetBytes',
    'withAnimatedPrefetchBudgetBytes',
)
require(
    'packages/sessions/test/download_job_test.dart',
    'animated frame credit pauses and resumes one response without reopen',
    'flowControl: ByteResponseFlowControl.streamBackpressure',
)
require(
    'packages/sessions/test/webp_frame_prefix_tracker_test.dart',
    'counts complete ANMF chunks across arbitrary fragment boundaries',
)
for path in (
    'docs/adr/0229-animated-webp-frame-flow-backpressure.md',
    'docs/audits/dev249-frame-flow-root-cause-audit.md',
    'docs/audits/dev249-validation-results.md',
):
    if not (ROOT / path).is_file():
        raise SystemExit(f'missing dev.249 governance file: {path}')
if build >= 268:
    require('docs/ARCHITECTURE.md', 'DownloadDemand窗口', 'frame credit', 'body-read permit')
    require('docs/SPEC.md', 'network-demand window：前 7 / 后 3', 'frame credit', 'body-read permit')
else:
    require('docs/ARCHITECTURE.md', 'DownloadDemand窗口', 'frame credit', 'streamBackpressure')
    require('docs/SPEC.md', 'network-demand window：前 7 / 后 3', 'frame credit', 'streamBackpressure')
require('tool/check.sh', 'test_dev249_animated_frame_flow_backpressure.py')
print('dev.249 animated WebP frame-flow backpressure: OK')

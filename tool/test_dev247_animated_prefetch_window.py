#!/usr/bin/env python3
"""Guard the stable 3/7 animated transfer window and role-local flow credit."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.247 contract: {missing}')


def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    if present:
        raise SystemExit(f'{path} contains superseded dev.247 coupling: {present}')

pubspec = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
if m is None or int(m.group(1)) < 247:
    raise SystemExit('App build must be >=247')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')

require(
    'packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart',
    'forwardEncodedPages: 7',
    'backwardEncodedPages: 3',
    'forwardDecodePages: 2',
    'backwardDecodePages: 1',
)
require(
    'packages/pipeline/lib/src/animated_prefetch_policy.dart',
    'These stages describe decode scheduling only.',
    "another page's decode waterline never controls its transfer",
    'if (readDistance == 1) return 5;',
    'if (readDistance == 2) return 3;',
    'if (readDistance == -1) return 2;',
    'return 1;',
    'targetFramesByIndex',
)
reject(
    'packages/pipeline/lib/src/animated_prefetch_policy.dart',
    'DecodeWaterlineStage.currentMid =>',
    'DecodeWaterlineStage.nextMid =>',
    'DecodeWaterlineStage.currentDeep =>',
    'DecodeWaterlineStage.nextDeep =>',
)
reject(
    'packages/pipeline/lib/src/pipeline_controller.dart',
    'observeDecodeWaterline',
    '_animatedPrefetchStage',
)
reject(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    '_handleDecodeRefillObserved',
    'onDecodeRefillObserved:',
    '.observeDecodeWaterline(',
)
require(
    'packages/pipeline/test/animated_prefetch_policy_test.dart',
    'animation keeps all logical 3/7 downloads and assigns frame flow credits',
    'far flow credit is role-local and independent of nearer decode progress',
    'static classification restores unlimited 3/7 flow',
)
for path in (
    'docs/archive/adr/0227-animated-webp-layered-prefetch-window.md',
    'docs/archive/audits/dev247-animated-prefetch-window-root-cause-audit.md',
    'docs/archive/audits/dev247-validation-results.md',
):
    if not (ROOT / path).is_file():
        raise SystemExit(f'missing dev.247 governance file: {path}')
require('docs/SPEC.md', 'network-demand window：前 7 / 后 3', '较近页的download/decode速度', 'frame credit')
require('docs/ARCHITECTURE.md', '同一页面自己的 role', 'decode waterline', 'frame credit')
require('tool/check.sh', 'test_dev247_animated_prefetch_window.py')
print('dev.247 stable 3/7 animated role-local flow contract: OK')

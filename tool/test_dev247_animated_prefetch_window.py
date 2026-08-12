#!/usr/bin/env python3
"""Guard dev.247 layered animated-WebP network admission without shrinking RoleWindow."""
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
    'animatedPrefetchBudgetBytes',
)
require(
    'packages/pipeline/lib/src/animated_prefetch_policy.dart',
    'minimumForwardPages = 4',
    'minimumBackwardPages = 2',
    'maximumForwardPages = 7',
    'maximumBackwardPages = 3',
    'defaultAnimatedWebpPrefetchBudgetBytes = 50 * 1024 * 1024',
    "'c>4' => 1",
    "'n>2' => 2",
    "'c>6' => 3",
    "'n>3' => 4",
    'minimumExceedsBudget',
    'window.roleOf(index) == PageRole.detached',
)
require(
    'packages/pipeline/lib/src/pipeline_controller.dart',
    '_animatedPrefetchStage = 0',
    'observeDecodeWaterline',
    'planRevision != _revision',
    'ContentKindHint.webp',
    "endsWith('.webp')",
    "'animatedPrefetchAdmittedIndexes'",
    "'animatedPrefetchMinimumExceededBudget'",
)
require(
    'packages/sessions/lib/src/live_coordinator.dart',
    'typedef DecodeRefillObserve',
    'onDecodeRefillObserved?.call(refill, demandRevision)',
    'after.depth + completedPreparedDepth >= refill.targetWatermark',
)
require(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    'onDecodeRefillObserved: _handleDecodeRefillObserved',
    '.observeDecodeWaterline(',
    'withAnimatedPrefetchBudgetBytes',
)
require(
    'apps/app/lib/app_preferences.dart',
    '_animatedWebpPrefetchBudgetMiB = 50',
    'setAnimatedWebpPrefetchBudgetMiB',
    "'animatedWebpPrefetchBudgetMiB'",
)
require(
    'apps/app/lib/demo_home_reader_route.dart',
    '.withAnimatedPrefetchBudgetBytes(',
    'animatedWebpPrefetchBudgetMiB * 1024 * 1024',
)
require(
    'apps/app/lib/app_settings_screen.dart',
    "'animated-webp-prefetch-budget'",
    '动画 WebP 预下载预算',
    'previous 2 / next 4',
)
require(
    'packages/pipeline/test/animated_prefetch_policy_test.dart',
    'preserves logical 3/7 window',
    'waterlines progressively open outer network pages',
    'byte budget never shrinks mandatory 2/4 floor',
    'resets staged expansion on jump',
)
for path in (
    'docs/adr/0227-animated-webp-layered-prefetch-window.md',
    'docs/audits/dev247-animated-prefetch-window-root-cause-audit.md',
    'docs/audits/dev247-validation-results.md',
):
    if not (ROOT / path).is_file():
        raise SystemExit(f'missing dev.247 governance file: {path}')
require('docs/SPEC.md', 'encoded逻辑/retention window', 'network下界previous2/next4')
require('docs/ARCHITECTURE.md', 'previous2/next4', 'c>4→next5')
require('tool/check.sh', 'test_dev247_animated_prefetch_window.py')
print('dev.247 animated WebP layered prefetch window: OK')

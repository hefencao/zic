#!/usr/bin/env python3
"""Ownership gate for dev.301 semantic demand revision/liveness boundary."""
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def read(path): return (ROOT/path).read_text(encoding='utf-8')
def current_dev():
    for line in read('apps/app/pubspec.yaml').splitlines():
        if line.startswith('version:') and '+' in line:
            return int(line.rsplit('+',1)[1].strip())
    raise SystemExit('FAIL: app version code missing')
def require(path,*tokens):
    text=read(path); missing=[t for t in tokens if t not in text]
    if missing: raise SystemExit(f'FAIL: {path} missing dev.301 tokens: {missing}')
def forbid(path,*tokens):
    text=read(path); found=[t for t in tokens if t in text]
    if found: raise SystemExit(f'FAIL: {path} contains forbidden dev.301 tokens: {found}')
if current_dev() == 301:
    require('apps/app/pubspec.yaml','version: 0.31.0+301')
    require('apps/app/android/zic-version.properties','versionCode=301')
elif current_dev() < 301:
    raise SystemExit('FAIL: dev.301 gate executed before dev.301')
require('packages/pipeline/lib/src/demand.dart',
        'bool sameSchedulingAs(DownloadDemand other)',
        'bool sameSchedulingAs(DecodeDemand other)',
        'bool sameSchedulingAs(UploadDemand other)',
        'sameScheduling: (a, b) => a.sameSchedulingAs(b)')
require('packages/pipeline/lib/src/pipeline_controller.dart',
        'final candidateRevision = _revision + 1;',
        ('if (!_decodeTargetDirty && diff.isEmpty)'
         if current_dev() >= 306
         else 'if (!windowChanged && !_decodeTargetDirty && diff.isEmpty)'),
        '_revision = candidateRevision;',
        'Never promote',
        '_runtimeWebpCostPages')
require('packages/sessions/lib/src/live_coordinator.dart',
        '_refreshDemandLiveness(update.plan);',
        'void _refreshDemandLiveness(DemandPlan plan)',
        'if (diff.isEmpty) return;',
        'Plan revision is liveness metadata',
        '_decodeDemandRevisions[id] = _revision;',
        '_uploadDemandRevisions[id] = _revision;',
        '_decodeDemandRevisions[id] ?? demandRevision')
require('packages/sessions/lib/src/coordinator.dart',
        'Refresh expiration/liveness metadata for semantically unchanged',
        '..addAll(update.plan.downloads)',
        '..addAll(update.plan.decodes)',
        '..addAll(update.plan.uploads)')
require('packages/pipeline/test/vertical_visible_policy_test.dart',
        'every reported vertical visible page changes foreground demand',
        'expect(controller.revision, greaterThan(revision));')
require('docs/archive/adr/0329-reader-navigation-resource-window-ownership.md',
        'vertical 中所有真实 `visibleCoverages.fraction > 0` 的非 current 页统一提升为 `PageRole.transition`',
        'MUST NOT 单独缩小 download/decode/upload window')
require('packages/pipeline/test/animated_prefetch_policy_test.dart',
        'offscreen runtime WebP evidence changes the one-frame static plan',
        'expect(controller.revision, revision + 1);',
        'expect(controller.revision, revision + 2);')
require('packages/pipeline/test/pipeline_test.dart',
        'demand diff separates liveness revision from scheduling identity',
        'DemandDiff.between(first, refreshed).isEmpty')
require('packages/sessions/test/fake_coordinator_test.dart',
        'refreshes liveness without demandApplied churn',
        'expirationRevision, 3')
require('packages/reader/lib/src/reader_view.dart',
        'Flutter delivers FrameTiming in batches',
        "'timingBatchIndex': index",
        "'timingBatchSize': timings.length",
        "'timingBatchCallbackMonotonicMicros': callbackMonotonicMicros",
        "'timingBatchLastVsyncStartMicros': batchLastVsyncStartMicros")
forbid('packages/reader/lib/src/reader_view.dart',
       "if (scrollPixels != null) 'scrollPixels': scrollPixels",
       "'viewportDimension': viewportDimension")
require('docs/archive/adr/0280-semantic-demand-revision-boundary.md',
        'expirationRevision','semantic diff','missed-vsync','rev46–49')
require('docs/archive/audits/dev301-semantic-demand-revision-root-cause-audit.md',
        '52.6ms','4 decodeDemand + 2 uploadDemand','UI Dart isolate')
require('docs/SPEC.md',
        '`expirationRevision` MUST只作为surviving demand的liveness metadata',
        'MUST NOT把callback时刻的scroll/current/interaction伪装成每个历史frame')
print('dev.301 semantic demand revision boundary: OK')

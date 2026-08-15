#!/usr/bin/env python3
"""Ownership gate for dev.302 atomic accepted-plan lane reconciliation."""
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
    if missing: raise SystemExit(f'FAIL: {path} missing dev.302 tokens: {missing}')
def forbid(path,*tokens):
    text=read(path); found=[t for t in tokens if t in text]
    if found: raise SystemExit(f'FAIL: {path} contains forbidden dev.302 tokens: {found}')
if current_dev() == 302:
    require('apps/app/pubspec.yaml','version: 0.31.0+302')
    require('apps/app/android/zic-version.properties','versionCode=302')
elif current_dev() < 302:
    raise SystemExit('FAIL: dev.302 gate executed before dev.302')
require('packages/sessions/lib/src/net_lane.dart',
        'void batch(void Function() action);',
        'int _batchDepth = 0;',
        'bool _pumpRequested = false;',
        'void _requestPump()',
        'if (_batchDepth > 0)',
        '_core.batch(action)')
require('packages/sessions/lib/src/live_coordinator.dart',
        'net.batch(() {', 'decode.batch(() {', 'upload.batch(() {',
        'TraceEventKind.pipelineReconcileTiming',
        "'atomicLaneBatch': true")
require('packages/sessions/lib/src/download_session.dart',
        'Priority belongs to transfer scheduling',
        'if (previous == null) {',
        '_notifySnapshot();')
require('packages/sessions/test/net_lane_test.dart',
        'batch defers lane pumping until the authoritative mutation commits',
        'expect(lane.active, 0);', 'expect(lane.queued, 3);')
if current_dev() == 302:
    require('packages/sessions/test/download_session_test.dart',
            'priority-only demand migration does not rebroadcast media snapshot',
            'expect(snapshots.length, afterAttach);')
else:
    require('packages/sessions/test/download_session_test.dart',
            'priority-only demand migration does not rebroadcast media snapshot')
require('packages/telemetry/lib/src/trace.dart','pipelineReconcileTiming')
require('apps/app/lib/debug_trace.dart',
        'event.kind != TraceEventKind.pipelineReconcileTiming')
require('packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart',
        'forwardEncodedPages: 7', 'backwardEncodedPages: 3',
        'forwardDecodePages: 2', 'backwardDecodePages: 1')
require('docs/adr/0281-atomic-lane-reconcile-transaction.md',
        'scheduling transaction','28/37','10.456ms','pipelineReconcileTiming')
require('docs/audits/dev302-atomic-lane-reconcile-root-cause-audit.md',
        '正确 revision 缺少 transaction boundary','11-download','UI isolate')
require('docs/SPEC.md',
        '一个accepted `DemandPlan`的sessions reconcile MUST作为单一scheduler transaction',
        '`pipelineReconcileTiming`')
forbid('packages/pipeline/lib/src/role_window.dart','dev.302')
print('dev.302 atomic lane reconcile transaction: OK')

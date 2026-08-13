#!/usr/bin/env python3
"""Guard dev.267 working-set/task separation under dev.268 response-lifetime supersession."""
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]
def read(p): return (ROOT/p).read_text(encoding='utf-8')
def req(c,m):
    if not c: raise SystemExit('FAIL: '+m)
pub=read('apps/app/pubspec.yaml')
m=re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$',pub,re.M)
req(m is not None and int(m.group(1))>=268,'App build must be >=268')
req(f'versionCode={m.group(1)}' in read('apps/app/android/zic-version.properties'),'Android version mismatch')
net=read('packages/sessions/lib/src/net_lane.dart')
owner=read('packages/sessions/lib/src/download_transfer_owner.dart')
for token in ('bool demanded = true','bool updateDemanded(String key, bool demanded)','bool? demandedOf(String key)'):
    req(token in net,f'NetLane demanded-state contract missing: {token}')
for token in ('net.updateDemanded(taskKey, false);',"reason: 'inactive-physical-retention'",'net.updateDemanded(taskKey, true);','net.cancelQueued(taskKey);'):
    req(token in owner,f'TransferOwner working-set lifetime contract missing: {token}')
remove=owner[owner.index('  void _removeClaim('):owner.index('  Future<void> _disposeConsumer',owner.index('  void _removeClaim('))]
req('net.cancel(taskKey)' not in remove,'logical _removeClaim must not cancel active task')
for stale in ('inactive-reclaim','_reclaimInactiveRunningFor','flowRetentionYieldable','requestFlowYield','pseudo-yielded','protectFlowRetentionFromNormalYield'):
    req(stale not in net and stale not in read('packages/sessions/lib/src/download_job.dart'),f'superseded scheduler patch remains: {stale}')
for token in ('int get running => _core.running;','int get parkedResponses => _core.parkedResponses;','releaseResponseReadPermit','acquireResponseReadPermit'):
    req(token in net,f'dev.268 response-lifetime owner missing: {token}')
pred=read('packages/pipeline/lib/src/browsing_direction_predictor.dart')
req('_candidateCount >= 2' in pred and '_history' not in pred and 'nowMicros' not in pred,'direction must remain working-set-only two-move confirmation')
req('working-set turn out and back reuses the same active physical task' in read('packages/sessions/test/download_transfer_owner_test.dart'),'TransferOwner turn-out/back identity regression missing')
for path in ('docs/adr/0245-working-set-physical-transfer-lifetime-separation.md','docs/audits/dev267-working-set-transfer-lifetime-root-cause-audit.md'):
    req((ROOT/path).is_file(),f'missing governance file {path}')
req('test_dev267_working_set_transfer_lifetime.py' in read('tool/check.sh'),'dev.267 gate not wired')
print('PASS: dev.267 working-set/task separation preserved; response lifetime strengthened by dev.268 parking')

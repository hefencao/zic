#!/usr/bin/env python3
"""Guard working-set vs physical transfer lifetime separation introduced in dev.267."""
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]
def read(p): return (ROOT/p).read_text(encoding='utf-8')
def req(c,m):
    if not c: raise SystemExit('FAIL: '+m)
pub=read('apps/app/pubspec.yaml')
m=re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$',pub,re.M)
req(m is not None and int(m.group(1))>=267,'App build must be >=267')
req(f'versionCode={m.group(1)}' in read('apps/app/android/zic-version.properties'),'Android version mismatch')
net=read('packages/sessions/lib/src/net_lane.dart')
owner=read('packages/sessions/lib/src/download_transfer_owner.dart')
for token in (
 'bool demanded = true','bool updateDemanded(String key, bool demanded)','bool? demandedOf(String key)',
 '_highestBlockedDemandedPending()','_reclaimInactiveRunningFor','task.demanded || !task.preemptible',
 "reason: 'inactive-reclaim'",'!pending.demanded'):
    req(token in net,f'NetLane demanded-state contract missing: {token}')
for token in (
 'net.updateDemanded(taskKey, false);',"reason: 'inactive-physical-retention'",
 'net.updateDemanded(taskKey, true);','net.cancelQueued(taskKey);',"'preemptionReason': preemption.reason"):
    req(token in owner,f'TransferOwner physical lifetime contract missing: {token}')
# Logical detach must not hard-cancel an admitted task in _removeClaim.
remove=owner[owner.index('  void _removeClaim('):owner.index('  Future<void> _disposeConsumer',owner.index('  void _removeClaim('))]
req('net.cancel(taskKey)' not in remove,'logical _removeClaim must not cancel active task')
for path in ('packages/sessions/lib/src/net_lane.dart','packages/sessions/lib/src/download_job.dart'):
    text=read(path)
    for stale in ('flowRetentionYieldable','requestFlowYield','pseudo-yielded','protectFlowRetentionFromNormalYield'):
        req(stale not in text,f'superseded flow/near scheduler patch remains in {path}: {stale}')
pred=read('packages/pipeline/lib/src/browsing_direction_predictor.dart')
req('_candidateCount >= 2' in pred and '_history' not in pred and 'nowMicros' not in pred,
    'direction must require two committed reverse moves without weighted trend')
nettest=read('packages/sessions/test/net_lane_test.dart')
for token in (
 'normal pressure never reclaims an active task that still has demand',
 'capacity pressure reclaims only an inactive admitted physical task',
 'reattaching demand protects the same admitted task from normal reclaim'):
    req(token in nettest,f'NetLane behavior regression missing: {token}')
ownertest=read('packages/sessions/test/download_transfer_owner_test.dart')
req('working-set turn out and back reuses the same active physical task' in ownertest,
    'TransferOwner turn-out/back identity regression missing')
ptest=read('packages/pipeline/test/browsing_direction_predictor_test.dart')
req('one-page reverse is a revisit, not a 3/7 working-set reversal' in ptest,
    'one-page reverse regression missing')
for path in ('docs/adr/0245-working-set-physical-transfer-lifetime-separation.md',
             'docs/audits/dev267-working-set-transfer-lifetime-root-cause-audit.md'):
    req((ROOT/path).is_file(),f'missing governance file {path}')
req('test_dev267_working_set_transfer_lifetime.py' in read('tool/check.sh'),'dev.267 gate not wired')
print('PASS: dev.267 working-set / physical transfer lifetime separation')

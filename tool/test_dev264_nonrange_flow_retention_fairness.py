#!/usr/bin/env python3
"""Preserve dev.264 starvation evidence while enforcing dev.268 scheduler supersession."""
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]
def read(p): return (ROOT/p).read_text(encoding='utf-8')
def req(c,m):
    if not c: raise SystemExit('FAIL: '+m)
build=int(re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$',read('apps/app/pubspec.yaml'),re.M).group(1))
req(build>=268,'dev.264 gate must run under dev.268+ supersession')
adr=read('docs/adr/0242-nonrange-flow-retention-slot-fairness.md')
req('Status: Superseded' in adr,'ADR0242 must remain superseded')
net=read('packages/sessions/lib/src/net_lane.dart')
job=read('packages/sessions/lib/src/download_job.dart')
for stale in ('flowRetentionYieldable','requestFlowYield','_requestYieldableFlowRetentionFor','inactive-reclaim','_reclaimInactiveRunningFor'):
    req(stale not in net,f'superseded slot-reclaim residue: {stale}')
req("action: 'pseudo-yielded'" not in job,'dev.264 DownloadJob pseudo-yield path must be removed')
if build >= 269:
    for token in ('int get running => _core.running;','int get demandedParkedResponses => _core.demandedParkedResponses;','int get inactiveParkedResponses => _core.inactiveParkedResponses;','releaseResponseReadPermit','acquireResponseReadPermit',"reason: 'inactive-response-retention-eviction'"):
        req(token in net,f'dev.269 response parking replacement missing: {token}')
    req("reason: 'parked-response-eviction'" not in net,'dev.268 mixed parked-pool eviction must be superseded')
else:
    for token in ('int get running => _core.running;','int get parkedResponses => _core.parkedResponses;','releaseResponseReadPermit','acquireResponseReadPermit',"reason: 'parked-response-eviction'"):
        req(token in net,f'dev.268 response parking replacement missing: {token}')
req(": 'pseudo-parked'" in job and 'responseRetained: true' in job,'DownloadJob parking replacement missing')
print('PASS: dev.264 starvation evidence preserved; slot-yield/reclaim patches superseded by live response parking')

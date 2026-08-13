#!/usr/bin/env python3
"""Preserve dev.264 starvation evidence while enforcing dev.267 supersession."""
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]
def read(p): return (ROOT/p).read_text(encoding='utf-8')
def req(c,m):
    if not c: raise SystemExit('FAIL: '+m)
build=int(re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$',read('apps/app/pubspec.yaml'),re.M).group(1))
req(build>=267,'dev.264 gate must run under dev.267+ supersession')
adr=read('docs/adr/0242-nonrange-flow-retention-slot-fairness.md')
req('Status: Superseded' in adr and 'ADR 0245' in adr,'ADR0242 must be superseded by ADR0245')
net=read('packages/sessions/lib/src/net_lane.dart')
job=read('packages/sessions/lib/src/download_job.dart')
for stale in ('flowRetentionYieldable','requestFlowYield','_requestYieldableFlowRetentionFor'):
    req(stale not in net,f'dev.264 NetLane flow-yield residue: {stale}')
req("action: 'pseudo-yielded'" not in job,'dev.264 DownloadJob pseudo-yield path must be removed')
for token in ('bool updateDemanded(String key, bool demanded)','_reclaimInactiveRunningFor','task.demanded','reason: \'inactive-reclaim\''):
    req(token in net,f'dev.267 physical demand-state replacement missing: {token}')
print('PASS: dev.264 evidence preserved; flow-level slot patch superseded by dev.267')

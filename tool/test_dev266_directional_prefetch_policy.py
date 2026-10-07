#!/usr/bin/env python3
"""Preserve one Pipeline direction fact while superseding dev.266 weighted trend/cancel coupling."""
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]
def read(p): return (ROOT/p).read_text(encoding='utf-8')
def req(c,m):
    if not c: raise SystemExit('FAIL: '+m)
build=int(re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$',read('apps/app/pubspec.yaml'),re.M).group(1))
req(build>=267,'dev.266 gate must run under dev.267+ supersession')
adr=read('docs/archive/adr/0244-pipeline-owned-browsing-direction.md')
req('Status: Superseded' in adr and 'ADR 0245' in adr,'ADR0244 must be superseded by ADR0245')
pred=read('packages/pipeline/lib/src/browsing_direction_predictor.dart')
for token in ('final class BrowsingDirectionPredictor','_candidateCount >= 2','delta.abs() > 5'):
    req(token in pred,f'simplified direction predictor missing {token}')
for stale in ('_history','nowMicros','dwell','trend'):
    req(stale not in pred,f'weighted/dwell direction residue remains: {stale}')
role=read('packages/pipeline/lib/src/role_window.dart')
flow=read('packages/pipeline/lib/src/animated_prefetch_policy.dart')
heur=read('packages/pipeline/lib/src/heuristic_policy.dart')
req('int readDirection = 1' in role and 'current + direction * offset' in role,'3/7 must consume Pipeline direction')
req('readDistance:' in flow and 'readDirection' in flow,'flow credit must consume same direction')
req('readDistance' in heur and 'readDirection' in heur,'rank must consume same direction')
print('PASS: dev.266 direction owner retained only as pure Pipeline working-set state')

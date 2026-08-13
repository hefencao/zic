#!/usr/bin/env python3
"""Preserve dev.265 near-two finding without retaining its cross-layer flag."""
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]
def read(p): return (ROOT/p).read_text(encoding='utf-8')
def req(c,m):
    if not c: raise SystemExit('FAIL: '+m)
build=int(re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$',read('apps/app/pubspec.yaml'),re.M).group(1))
req(build>=267,'dev.265 gate must run under dev.267+ supersession')
adr=read('docs/adr/0243-near-two-flow-retention-protection.md')
req('Status: Superseded' in adr and 'ADR 0245' in adr,'ADR0243 must be superseded by ADR0245')
for path in (
 'packages/pipeline/lib/src/demand.dart','packages/pipeline/lib/src/heuristic_policy.dart',
 'packages/sessions/lib/src/download_transfer_owner.dart','packages/sessions/lib/src/net_lane.dart',
 'packages/sessions/lib/src/download_job.dart'):
    text=read(path)
    req('protectFlowRetentionFromNormalYield' not in text,f'near-two flag remains in {path}')
req('demanded=true' in read('docs/adr/0245-working-set-physical-transfer-lifetime-separation.md'),
    'ADR0245 must protect all demanded active tasks independent of Reader distance')
print('PASS: dev.265 near-two evidence preserved without near-distance scheduler patch')

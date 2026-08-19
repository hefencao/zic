#!/usr/bin/env python3
import json, statistics, sys
from pathlib import Path

if len(sys.argv) != 2:
    raise SystemExit('usage: analyze_prefetch_direction_flip_jank.py TRACE.jsonl')
path=Path(sys.argv[1])
events=[]
for line in path.read_text(encoding='utf-8').splitlines():
    try: events.append(json.loads(line))
    except json.JSONDecodeError: pass
flips=[e for e in events if e.get('kind')=='pipelineReconcileTiming' and e.get('payload',{}).get('downloadAdded')==5 and e.get('payload',{}).get('downloadRemoved')==5]
other=[e for e in events if e.get('kind')=='pipelineReconcileTiming' and e not in flips]
def med(rows):
    vals=[e['payload'].get('reconcileMicros',0) for e in rows]
    return int(statistics.median(vals)) if vals else 0
frames=[]
for e in events:
    if e.get('kind')!='readerFrameTiming': continue
    p=e.get('payload',{})
    vs,last,cb=p.get('vsyncStartMicros'),p.get('timingBatchLastVsyncStartMicros'),p.get('timingBatchCallbackMonotonicMicros')
    if not all(isinstance(x,(int,float)) for x in (vs,last,cb)): continue
    frames.append((cb-(last-vs),p.get('buildMicros',0)))
flip_t=[e['t'] for e in flips]
near=[b for t,b in frames if any(abs(t-f)<=15000 for f in flip_t)]
far=[b for t,b in frames if not any(abs(t-f)<=15000 for f in flip_t)]
heavy=[(t,b) for t,b in frames if b>=10000]
heavy_near=sum(any(abs(t-f)<=15000 for f in flip_t) for t,b in heavy)
print(f'flip_5x5_reconciles={len(flips)} median_reconcile_us={med(flips)}')
print(f'other_reconciles={len(other)} median_reconcile_us={med(other)}')
print(f'build_ge_10ms={len(heavy)} associated_with_flip={heavy_near}')
print(f'near_flip_build_median_us={int(statistics.median(near)) if near else 0}')
print(f'away_from_flip_build_median_us={int(statistics.median(far)) if far else 0}')

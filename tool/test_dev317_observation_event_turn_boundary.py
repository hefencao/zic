#!/usr/bin/env python3
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]
def read(p): return (ROOT/p).read_text(encoding='utf-8')
def require(text, token, label):
    if token not in text: raise SystemExit(f'dev.317 missing {label}: {token}')
def forbid(text, token, label):
    if token in text: raise SystemExit(f'dev.317 forbidden {label}: {token}')
version=read('apps/app/pubspec.yaml'); props=read('apps/app/android/zic-version.properties')
m=re.search(r'^version: 0\.31\.0\+(\d+)$', version, re.M)
if m is None or int(m.group(1)) < 317:
    raise SystemExit('dev.317+ version mismatch')
code=int(m.group(1))
if not re.search(rf'^versionCode={code}$', props, re.M):
    raise SystemExit('dev.317+ Android version mismatch')
session=read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
for token in ('void enqueueObservation(ReaderObs observation)','_pendingObservation = observation;','_sameVerticalControlObservation','_observationDrainScheduled','Timer.run(() => _drainObservation(generation));'):
    require(session, token, 'latest-wins ordinary-event-turn seam')
region=session[session.index('void _scheduleObservationDrain()'):session.index('void _drainObservation(int generation)')]
forbid(region, 'scheduleMicrotask(()', 'observation drain microtask call')
# Keep unrelated callback microtasks untouched so this remains a single-variable experiment.
for token in ('void _handleSourceKindObserved','void _handleDecodeRefillObserved','void _handleAnimationResolved'):
    start=session.index(token)
    end=min([x for x in (session.find('\n  void ', start+5), session.find('\n  Future<', start+5)) if x != -1] or [len(session)])
    require(session[start:end], 'scheduleMicrotask(()', f'unchanged callback microtask in {token}')
for token in ('Duration(milliseconds: 180)','SchedulerBinding.instance','encodedFlutterPresentation','staticEncodedPresentation'):
    forbid(session, token, 'unrelated experiment behavior')
predictor=read('packages/pipeline/lib/src/browsing_direction_predictor.dart')
for token in ('Only a second committed','_candidateCount >= 2'):
    require(predictor, token, 'dev.313 predictor rollback')
for token in ('reversalDistancePages = 4','_candidateDistance += delta.abs()'):
    forbid(predictor, token, 'falsified dev.316 predictor')
for rel in ('tool/analyze_frame_between_control_jank.py','docs/adr/0296-reader-observation-event-turn-boundary.md','docs/audits/dev317-observation-event-turn-jank-audit.md'):
    if not (ROOT/rel).is_file(): raise SystemExit(f'dev.317 missing artifact: {rel}')
docs=''.join(read(p) for p in ('CHANGELOG.md','docs/IMPLEMENTATION_PLAN.md','docs/IMPLEMENTATION_STATUS.md','docs/NEXT_CHAT_HANDOFF.md','docs/adr/0296-reader-observation-event-turn-boundary.md','docs/audits/dev317-observation-event-turn-jank-audit.md'))
for token in ('66','55','build','raster','ordinary event','FALSIFIED'):
    require(docs, token, '14:39 evidence/governance')
print('dev.317 Reader observation ordinary-event-turn boundary: OK')

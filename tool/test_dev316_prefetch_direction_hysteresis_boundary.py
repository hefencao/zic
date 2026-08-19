#!/usr/bin/env python3
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]
def read(p): return (ROOT/p).read_text(encoding='utf-8')
version=read('apps/app/pubspec.yaml'); props=read('apps/app/android/zic-version.properties')
m=re.search(r'^version: 0\.31\.0\+(\d+)$', version, re.M)
if m is None or 'versionCode=' not in props: raise SystemExit('dev.316 version metadata missing')
code=int(m.group(1))
predictor=read('packages/pipeline/lib/src/browsing_direction_predictor.dart')
if code == 316:
    for token in ('reversalDistancePages = 4','_candidateDistance += delta.abs()','movement == _direction'):
        if token not in predictor: raise SystemExit(f'dev.316 missing predictor boundary: {token}')
elif code >= 317:
    for token in ('reversalDistancePages = 4','_candidateDistance += delta.abs()'):
        if token in predictor: raise SystemExit(f'dev.316 falsified predictor behavior retained after rollback: {token}')
    for token in ('Only a second committed','_candidateCount >= 2'):
        if token not in predictor: raise SystemExit(f'dev.317+ missing restored dev.313 predictor behavior: {token}')
else:
    raise SystemExit('dev.316 gate requires dev.316+')
# Production must keep dev.313 media semantics after dev.314/dev.315 rollback.
policy=read('packages/pipeline/lib/src/heuristic_policy.dart')
player=read('packages/local_media_ui/lib/src/local_image_player.dart')
session=read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
for forbidden in ('encodedFlutterPresentation','_pipelineAuthoritativeStatic','staticEncodedPresentation','runtimeWebpPages: _runtimeWebpCostPages'):
    if forbidden in policy+player+session: raise SystemExit(f'dev.316+ retained falsified dev.315 behavior: {forbidden}')
if 'runtimeLocalStaticPages.contains(entry.key)' not in policy:
    raise SystemExit('dev.316+ did not restore dev.313 local-static pre-presentation behavior')
for rel in ('docs/adr/0293-fixed-position-hidden-static-upload-boundary.md','docs/adr/0294-static-webp-encoded-flutter-presentation-boundary.md','docs/adr/0295-prefetch-direction-hysteresis-boundary.md','docs/audits/dev316-prefetch-direction-jank-audit.md'):
    if not (ROOT/rel).is_file(): raise SystemExit(f'dev.316 missing governance artifact: {rel}')
docs=''.join(read(p) for p in ('CHANGELOG.md','docs/IMPLEMENTATION_STATUS.md','docs/NEXT_CHAT_HANDOFF.md','docs/adr/0295-prefetch-direction-hysteresis-boundary.md','docs/audits/dev316-prefetch-direction-jank-audit.md'))
for token in ('378','7.425','1.289','14.617','1.637','FALSIFIED'):
    if token not in docs: raise SystemExit(f'dev.316 missing evidence: {token}')
if code >= 317 and 'rolled back in dev.317' not in read('CHANGELOG.md'):
    raise SystemExit('dev.317+ must record dev.316 as falsified/rolled back')
print('dev.316 prefetch direction hysteresis boundary: OK')

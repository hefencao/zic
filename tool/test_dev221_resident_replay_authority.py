#!/usr/bin/env python3
import re
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
def read(p): return (ROOT/p).read_text(encoding='utf-8')
def req(text, token, label):
    if token not in text: raise SystemExit(f'dev.221 missing {label}: {token}')
def forbid(text, token, label):
    if token in text: raise SystemExit(f'dev.221 forbidden {label}: {token}')
pub=read('apps/app/pubspec.yaml')
vm=re.search(r'^version: 0\.31\.0\+(\d+)$', pub, re.M)
version=int(vm.group(1)) if vm else 0
session=read('packages/sessions/lib/src/download_session.dart')
registry=read('packages/sessions/lib/src/download_ingress_registry.dart')
pipe=read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
test=read('packages/sessions/test/download_session_test.dart')
live=read('packages/sessions/test/live_coordinator_test.dart')
if version >= 292:
    for token in ('typedef DownloadResidentReplayChunks', 'typedef DownloadResidentReplaySource', 'residentReplayChunks', 'if (_residentBodyBacked)', 'await replay(targetLength)', 'artifact.readChunks(endExclusive: targetLength)'):
        req(session, token, 'physical/replay split')
    for token in ('DownloadResidentReplaySource? residentReplaySource', 'session.residentBodyBacked', 'return replay(session, endExclusive);'):
        req(registry, token, 'Reader-local replay authority injection')
    runtime=read('packages/downloads/lib/src/composition_download_transfer_runtime.dart')
    for token in ('DownloadResidentReplaySource residentReplaySource(', 'await cache.lookup(session.id', 'owner.openResidentReplay(', 'localReadScheduler.acquire('):
        req(runtime, token, 'composition replay routing')
    forbid(pipe, '_openResidentReplaySource(', 'Pipeline-private resident replay backend selector')
    req(pipe, '_transferRuntime.residentReplaySource(', 'Pipeline composition replay capability')
else:
    for token in ('typedef DownloadIngressReplayChunks', 'residentReplayChunks', 'if (_residentBodyBacked)', 'chunks = await replay(targetLength);', 'chunks = artifact.readChunks(endExclusive: targetLength);'):
        req(session, token, 'physical/replay split')
    for token in ('typedef ResidentIngressReplaySource', 'this.residentReplaySource', 'session.residentBodyBacked', 'return replay(session, endExclusive);'):
        req(registry, token, 'Reader-local replay authority injection')
    for token in ('residentReplaySource: _openResidentReplaySource', 'final cache = _artifactCacheManager;', 'await cache.lookup(session.id)', '_isDirectImmutableLocalUri(uri)', 'artifactReadScheduler.acquire(', '_boundedResidentReplay(', '_scheduledResidentReplay('):
        req(pipe, token, 'composition replay routing')
forbid(session, 'package:downloads/', 'sessions depending on durable cache implementation')
req(test, 'resident-cache late Reader replays from external byte authority', 'resident artifact regression')
req(test, 'expect(session.artifact.committedLength, 0);', 'no duplicate session artifact assertion')
req(live, 'residentReplaySource: (physical, endExclusive) async', 'late coordinator resident replay regression')
for rel in ('docs/adr/0202-resident-encoded-source-replay-authority.md','docs/audits/dev221-resident-replay-root-cause-audit.md','docs/audits/dev221-validation-results.md'):
    if not (ROOT/rel).exists(): raise SystemExit(f'dev.221 missing governance: {rel}')
props=read('apps/app/android/zic-version.properties')
m=re.search(r'^version: 0\.31\.0\+(\d+)$',pub,re.M); a=re.search(r'^versionCode=(\d+)$',props,re.M)
if m is None or int(m.group(1)) < 221 or a is None or int(a.group(1)) < 221: raise SystemExit('dev.221 version mismatch')
print('dev.221 resident encoded-source replay authority: OK')

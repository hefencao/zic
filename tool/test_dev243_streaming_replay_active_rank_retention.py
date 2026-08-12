#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(cond: bool, message: str) -> None:
    if not cond:
        raise SystemExit(f'FAIL: {message}')

pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
projection = read('packages/sessions/lib/src/download_ingress_projection.dart')
session = read('packages/sessions/lib/src/download_session.dart')
owner = read('packages/sessions/lib/src/download_transfer_owner.dart')
session_test = read('packages/sessions/test/download_session_test.dart')
owner_test = read('packages/sessions/test/download_transfer_owner_test.dart')
live_test = read('packages/sessions/test/live_coordinator_test.dart')
arch = read('docs/ARCHITECTURE.md')
spec = read('docs/SPEC.md')
check = read('tool/check.sh')

m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
require(m is not None and int(m.group(1)) >= 243, 'App build must be >=243')
m2 = re.search(r'^versionCode=(\d+)\s*$', props, re.M)
require(m2 is not None and m2.group(1) == m.group(1), 'Android versionCode must match App build')

require('_synchronizedReplayPending' in projection, 'late ingress replay must have an unpublished staging state')
require('EncodedSource? get source =>' in projection and '? null : ingress.source' in projection,
        'decode must not observe a late replay source before authoritative publication')
require('void beginSynchronizedReplay()' in projection and 'void finishSynchronizedReplay()' in projection,
        'late replay publication must be explicit')
require('projection.beginSynchronizedReplay();' in session and 'projection.finishSynchronizedReplay();' in session,
        'DownloadSession must bracket synchronized late replay publication')
require('artifact.readChunks(' in session and 'start: offset' in session and 'endExclusive: targetLength' in session,
        'same-epoch moving boundary must append only the newly committed artifact suffix')
require('final canAppendSuffix = !_residentBodyBacked' in session,
        'incremental catch-up must stay on hot artifact-backed physical sessions')
require('late Reader projection stays unpublished until replay is authoritative' in session_test,
        'late replay publication regression is required')
require('expect(projection.source, isNull);' in session_test and
        'expect(identical(projectionB.source, projectionBSource), isTrue);' in session_test,
        'tests must prove hidden replay and stable post-attach source identity')

require('taskKey != null && taskIsActive' in owner and
        'Logical demand detachment never decides whether already-admitted work' in owner,
        'active admitted work must survive logical detach independently of DownloadState taxonomy')
require("reason: 'retained-background'" in owner, 'detached active work must migrate to rank zero')
require('final receiving = session?.state == DownloadState.receiving;' not in owner,
        'receiving/pre-open state taxonomy must not decide active retention')
require('A pre-open run is not worth retaining' not in owner,
        'pre-open direct cancellation policy must be removed')
require('net.cancelQueued(taskKey);' in owner,
        'never-admitted queued work may still be discarded without paid-work loss')
require('detached active pre-open work drops to rank zero and yields by NetLane policy' in owner_test,
        'physical owner regression must prove active pre-open retention then scheduler preemption')
require('expect(net.priorityOf(openingKey), 0);' in owner_test and
        'expect(opening.cancelled.isCompleted, isFalse);' in owner_test,
        'logical detach must not itself cancel an active pre-open task')
require('detached pre-open run drops to rank zero and yields its slot by policy' in live_test,
        'live coordinator regression must preserve cross-session rank handoff')

require('unpublished' in arch and '同一SourceEpoch' in arch,
        'Architecture must freeze atomic late-replay publication/catch-up ownership')
require('active/admitted' in spec and 'rank 0' in spec,
        'SPEC must freeze logical-detach versus active-task rank ownership')
for path in (
    'docs/adr/0223-atomic-late-ingress-and-active-rank-zero-retention.md',
    'docs/audits/dev243-streaming-cancel-rank-root-cause-audit.md',
):
    require((ROOT / path).is_file(), f'missing governance file: {path}')
require('test_dev243_streaming_replay_active_rank_retention.py' in check,
        'release gate wiring')

print('PASS: dev.243 streaming replay + active rank-zero retention')

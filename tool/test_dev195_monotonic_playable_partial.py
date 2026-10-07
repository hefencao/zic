#!/usr/bin/env python3
"""Guard dev.195's dev.192-restart playable-partial ownership boundary."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
JOB = (ROOT / 'packages/sessions/lib/src/download_job.dart').read_text(encoding='utf-8')
SESSION = (ROOT / 'packages/sessions/lib/src/download_session.dart').read_text(encoding='utf-8')
JOB_TEST = (ROOT / 'packages/sessions/test/download_job_test.dart').read_text(encoding='utf-8')
SESSION_TEST = (ROOT / 'packages/sessions/test/download_session_test.dart').read_text(encoding='utf-8')
CHANGELOG = (ROOT / 'CHANGELOG.md').read_text(encoding='utf-8')
STATUS = (ROOT / 'docs/IMPLEMENTATION_STATUS.md').read_text(encoding='utf-8')
ADR = (ROOT / 'docs/archive/adr/0176-monotonic-playable-partial-full-body-prefix-catchup.md').read_text(encoding='utf-8')

for token in (
    "strategy: 'full-body-prefix-catchup'",
    'playablePrefixPreserved: true',
    '_verifyFullBodyPrefix(',
    '_checksumExistingArtifact(',
    'final checksum = Crc32();',
    'expectedChecksum: session.artifact.checksum',
    'full response prefix differs from the existing playable partial',
):
    if token not in JOB:
        raise SystemExit(f'dev.195 full-body catch-up contract missing: {token}')

checksum_block = JOB[
    JOB.index('Future<String> _checksumExistingArtifact('):
    JOB.index('Future<Uint8List> _readExistingArtifact(')
]
for token in ('session.artifact.readChunks(', 'final checksum = Crc32();', 'checksum.add(iterator.current);'):
    if token not in checksum_block:
        raise SystemExit(f'dev.195 streaming partial checksum missing: {token}')
if 'BytesBuilder' in checksum_block or '_readExistingArtifact(' in checksum_block:
    raise SystemExit('dev.195 full-body checksum must not materialize the preserved partial')

# There may still be reset() for a brand-new durable-cache ingress failure, but
# ordinary partial resume fallback must not reset the playback authority.
resume_block = JOB[JOB.index('final preservedLength = session.committedLength;'):
                   JOB.index('session.acquireWriter(')]
if 'session.reset()' in resume_block:
    raise SystemExit('dev.195 resume fallback still resets an existing partial')

for token in (
    'Future<void> _restoreIngressIfNeeded({required bool sealed})',
    'if (alreadyAuthoritative)',
    'await _restoreIngressIfNeeded(sealed: false)',
    'await _restoreIngressIfNeeded(sealed: true)',
):
    if token not in SESSION:
        raise SystemExit(f'dev.195 idempotent ingress restore missing: {token}')

for token in (
    'validatorless restart keeps playable ingress while full body catches up',
    'preserves the existing playable partial',
    'validator mismatch catches up full body without shrinking partial',
):
    if token not in JOB_TEST:
        raise SystemExit(f'dev.195 download job regression missing: {token}')
if 'corrupt resume metadata preserves committed media bytes' not in SESSION_TEST:
    raise SystemExit('dev.195 metadata preservation regression missing')

# This clean restart must not move the fix into decode or introduce bandwidth policy.
for relative in ('packages/sessions/lib/src/decode_session.dart',
                 'packages/sessions/lib/src/net_lane.dart',
                 'packages/pipeline_runtime/lib', 'apps/app/lib'):
    path = ROOT / relative
    paths = [path] if path.is_file() else path.rglob('*.dart')
    for item in paths:
        body = item.read_text(encoding='utf-8')
        for forbidden in ('full-body-prefix-catchup', 'playablePrefixPreserved'):
            if forbidden in body:
                raise SystemExit(f'dev.195 partial lifecycle leaked into {item.relative_to(ROOT)}')

pubspec = (ROOT / 'apps/app/pubspec.yaml').read_text(encoding='utf-8')
properties = (ROOT / 'apps/app/android/zic-version.properties').read_text(encoding='utf-8')
app = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.MULTILINE)
android = re.search(r'^versionCode=(\d+)$', properties, re.MULTILINE)
if app is None or int(app.group(1)) < 195:
    raise SystemExit('dev.195-or-newer app build missing')
if android is None or int(android.group(1)) < 195:
    raise SystemExit('dev.195-or-newer Android version missing')

for path in (
    ROOT / 'docs/archive/adr/0176-monotonic-playable-partial-full-body-prefix-catchup.md',
    ROOT / 'docs/archive/audits/dev195-dev192-restart-playable-partial-root-cause-audit.md',
    ROOT / 'docs/archive/audits/dev195-validation-results.md',
):
    if not path.exists():
        raise SystemExit(f'dev.195 release document missing: {path.relative_to(ROOT)}')

for body, name in ((CHANGELOG, 'CHANGELOG'), (STATUS, 'status')):
    if 'dev.195' not in body:
        raise SystemExit(f'dev.195 missing from {name}')
if 'dev.193' not in ADR or 'dev.194' not in ADR or '被否决' not in ADR:
    raise SystemExit('dev.195 ADR does not quarantine rejected dev.193/dev.194 line')

print('dev.195 monotonic playable partial ownership: OK')

#!/usr/bin/env python3
"""Guard dev.196 validatorless Range probe and duplicate-traffic boundary."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
JOB = (ROOT / 'packages/sessions/lib/src/download_job.dart').read_text(encoding='utf-8')
SESSION = (ROOT / 'packages/sessions/lib/src/download_session.dart').read_text(encoding='utf-8')
RHTTP = (ROOT / 'packages/downloads_bridge/lib/src/rhttp_source_resource_transport.dart').read_text(encoding='utf-8')
JOB_TEST = (ROOT / 'packages/sessions/test/download_job_test.dart').read_text(encoding='utf-8')
ARCH = (ROOT / 'docs/ARCHITECTURE.md').read_text(encoding='utf-8')
SPEC = (ROOT / 'docs/SPEC.md').read_text(encoding='utf-8')
STATUS = (ROOT / 'docs/IMPLEMENTATION_STATUS.md').read_text(encoding='utf-8')
HANDOFF = (ROOT / 'docs/NEXT_CHAT_HANDOFF.md').read_text(encoding='utf-8')

for token in (
    'const int _validatorlessResumeProbeBytes = 64 * 1024;',
    '_openRange(probeStart, cancel)',
    'response.isPartial &&',
    'response.rangeStart == probeStart',
    'final responseTotalLength = response.totalLength;',
    'responseTotalLength >= preservedLength',
    'preservedTotalLength == null ||',
    'responseTotalLength == preservedTotalLength',
    '_verifyArtifactOverlap(',
    "strategy: 'validatorless-range-probe'",
    "'resumeProbeStart': probeStart",
    "'resumeProbeBytes': probeBytes",
    "'resumeProbeStatusCode': response.statusCode",
    "'resumeProbeAccepted': true",
    "'duplicatePrefixBytes': duplicatePrefixBytes",
    "'fullBodyResponseReused': true",
):
    if token not in JOB:
        raise SystemExit(f'dev.196 validatorless Range contract missing: {token}')

if 'for (var index = 0; index < take; index++)' not in JOB:
    raise SystemExit('dev.196 overlap proof is not byte-exact')
if 'session.artifact.readChunks(' not in JOB:
    raise SystemExit('dev.196 overlap proof does not read authoritative artifact bytes')

resume_block = JOB[JOB.index('final preservedLength = session.committedLength;'):
                   JOB.index('session.acquireWriter(')]
if 'session.reset()' in resume_block:
    raise SystemExit('dev.196 resume strategy can still reset playable partial')

for token in (
    'validatorless range ignored reuses the same full response for catchup',
    'validatorless overlap mismatch preserves the existing playable partial',
    'expect(ignoredRange.requests, hasLength(1))',
    'expect(ignoredRange.discardCount, 0)',
):
    if token not in JOB_TEST:
        raise SystemExit(f'dev.196 resume regression missing: {token}')


for token in (
    'validatePrefix: !request.requiresRuntimeTransform &&',
    '(parsedRange == null || parsedRange.start == 0),',
    'bool validatePrefix = true',
    'if (validatePrefix) {',
):
    if token not in RHTTP:
        raise SystemExit(f'dev.196 rhttp partial-range contract missing: {token}')

if 'Map<String, Object?> diagnostics = const <String, Object?>{}' not in SESSION:
    raise SystemExit('dev.196 resume trace diagnostics seam missing')

# Diagnostics remain observation-only and must not become scheduling/presentation policy.
for relative in (
    'packages/sessions/lib/src/net_lane.dart',
    'packages/sessions/lib/src/decode_session.dart',
    'packages/pipeline_runtime/lib',
    'apps/app/lib',
):
    path = ROOT / relative
    paths = [path] if path.is_file() else path.rglob('*.dart')
    for item in paths:
        body = item.read_text(encoding='utf-8')
        for forbidden in ('resumeProbeStart', 'duplicatePrefixBytes', 'validatorless-range-probe'):
            if forbidden in body:
                raise SystemExit(
                    f'dev.196 resume diagnostics leaked into policy owner {item.relative_to(ROOT)}'
                )

for body, name in ((ARCH, 'architecture'), (SPEC, 'spec')):
    if '64 KiB' not in body or 'Range' not in body or 'full' not in body:
        raise SystemExit(f'dev.196 stable resume contract missing from {name}')

pubspec = (ROOT / 'apps/app/pubspec.yaml').read_text(encoding='utf-8')
properties = (ROOT / 'apps/app/android/zic-version.properties').read_text(encoding='utf-8')
app = re.search(r'^version: \d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)$', pubspec, re.MULTILINE)
android = re.search(r'^versionCode=(\d+)$', properties, re.MULTILINE)
if app is None or int(app.group(1)) < 196:
    raise SystemExit('dev.196-or-newer app build missing')
if android is None or int(android.group(1)) < 196:
    raise SystemExit('dev.196-or-newer Android version missing')

for path in (
    ROOT / 'docs/archive/adr/0177-validatorless-range-probe-duplicate-traffic.md',
    ROOT / 'docs/archive/audits/dev196-duplicate-traffic-root-cause-audit.md',
    ROOT / 'docs/archive/audits/dev196-validation-results.md',
):
    if not path.exists():
        raise SystemExit(f'dev.196 release document missing: {path.relative_to(ROOT)}')

for body, name in ((STATUS, 'status'), (HANDOFF, 'handoff')):
    if 'dev.196' not in body:
        raise SystemExit(f'dev.196 missing from {name}')

print('dev.196 validatorless range probe duplicate traffic: OK')

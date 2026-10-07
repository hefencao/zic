#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
read = lambda p: (ROOT / p).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.235 missing {label}: {token}')

def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'dev.235 forbidden {label}: {token}')

pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
build = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.M)
android = re.search(r'^versionCode=(\d+)$', props, re.M)
if build is None or int(build.group(1)) < 235:
    raise SystemExit('dev.235 app version missing')
if android is None or android.group(1) != build.group(1):
    raise SystemExit('dev.235 Android version mismatch')

session = read('packages/sessions/lib/src/download_session.dart')
job = read('packages/sessions/lib/src/download_job.dart')
owner = read('packages/sessions/lib/src/download_transfer_owner.dart')
partial = read('packages/downloads/lib/src/partial_download_handoff.dart')
chapter = read('packages/downloads/lib/src/chapter_downloads.dart')
persistent_store = read('packages/downloads/lib/src/persistent_download_artifact_store.dart')
partial_resume = read('packages/downloads/lib/src/persistent_download_partial_resume.dart')
download_storage = chapter + persistent_store + partial_resume
pipeline = read('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart')
job_test = read('packages/sessions/test/download_job_test.dart')
owner_test = read('packages/sessions/test/download_transfer_owner_test.dart')
partial_test = read('packages/downloads/test/partial_download_handoff_test.dart')
session_test = read('packages/sessions/test/download_session_test.dart')

for token in (
    'Uri? _validatorRequestUri;',
    'Validators resumeValidatorsFor(Uri requestUri)',
    'bool hasValidatorsForOtherRequest(Uri requestUri)',
    "'version': 3,",
    "'validatorRequestUri': _validatorRequestUri.toString(),",
    "final rawValidatorRequestUri = meta['validatorRequestUri'];",
    'restoredValidatorRequestUri == null',
):
    require(session, token, 'provider-scoped session validator authority')
for token in (
    'residentCacheBacked',
    'beginDurableCachedIngress',
    'appendDurableCachedIngress',
    'sealDurableCachedIngress',
):
    forbid(session, token, 'obsolete test-only resident compatibility alias')

for token in (
    'final resumeValidators = session.resumeValidatorsFor(_requestUri);',
    'session.hasValidatorsForOtherRequest(_requestUri)',
    'expectedValidators: resumeValidators,',
    'validatorRequestUri: _requestUri,',
    "'providerValidatorMismatch': true",
):
    require(job, token, 'exact provider resume behavior')
forbid(job, 'validators: session.validators', 'raw physical validator network request')
forbid(job, 'expectedValidators: session.validators', 'raw physical validator resume check')

for token in (
    'session.resumeValidatorsFor(sourceId.canonicalUri)',
    'validators: resumeValidators.canResume ? resumeValidators : null,',
):
    require(owner, token, 'resident replay exact provider scope')
require(partial, 'session.resumeValidatorsFor(targetId.canonicalUri)', 'cold partial physical validator scope')
if int(build.group(1)) >= 273:
    require(download_storage, 'validatorRequestUri != id.canonicalUri', 'persistent indexed partial validator scope')
    require(download_storage, '_readIndexedPartialResumeState(record.path, id)', 'persistent indexed partial resume authority')
else:
    require(chapter, 'session.resumeValidatorsFor(id.canonicalUri)', 'persistent exact partial validator scope')
if int(build.group(1)) >= 292:
    require(pipeline, 'session.resumeValidatorsFor(asset.uri)', 'direct immutable presentation provider scope')
    forbid(pipeline, '_openResidentReplaySource(', 'Pipeline-private resident replay provider scope')
else:
    for token in (
        'session.resumeValidatorsFor(uri)',
        'session.resumeValidatorsFor(asset.uri)',
    ):
        require(pipeline, token, 'immutable replay provider scope')

# No raw DownloadSession validator may be used as a production transport validator.
for rel in (
    'packages/sessions/lib',
    'packages/downloads/lib',
    'packages/pipeline_runtime/lib',
    'apps/app/lib',
):
    base = ROOT / rel
    if not base.exists():
        continue
    for path in base.rglob('*.dart'):
        text = path.read_text(encoding='utf-8')
        if 'session.validators' in text:
            raise SystemExit(
                f'dev.235 raw session validator leaked into production: {path.relative_to(ROOT)}'
            )

for token in (
    'equivalent provider URI never reuses foreign resume validators',
    'newProvider.requests.single.validators, isNull',
):
    require(job_test, token, 'provider mismatch behavior regression')
for token in (
    'equivalent failed partial resumes through provider exact request URI',
    'transport.validatorsSeen.first, isNull',
    "Validators(etag: 'new-provider-v2')",
):
    require(owner_test, token, 'physical alias exact provider regression')
require(partial_test, 'physical partial never persists validators from an aliased provider', 'cold partial validator regression')
require(session_test, 'legacy unscoped resume validators are discarded but length survives', 'v2 metadata migration regression')

for rel in (
    'docs/archive/adr/0215-provider-scoped-resume-validators.md',
    'docs/archive/audits/dev235-partial-reuse-redundant-download-root-cause-audit.md',
    'docs/archive/audits/dev235-validation-results.md',
):
    if not (ROOT / rel).exists():
        raise SystemExit(f'dev.235 governance file missing: {rel}')

print('dev.235 provider-scoped resume validators: OK')

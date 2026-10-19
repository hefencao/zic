#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'dev.227 missing {label}: {token}')

def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'dev.227 forbidden {label}: {token}')

job = read('packages/sessions/lib/src/download_job.dart')
owner = read('packages/sessions/lib/src/download_transfer_owner.dart')
test = read('packages/sessions/test/download_transfer_owner_test.dart')

for token in (
    'this.requestUri,',
    'final Uri? requestUri;',
    'Uri get _requestUri => requestUri ?? session.id.canonicalUri;',
    'controlled.openControlled(\n          _requestUri,',
    'transport.open(\n        _requestUri,',
    'transport.open(_requestUri)',
):
    require(job, token, 'provider exact request URI in DownloadJob')

# The legacy fallback is allowed only in the requestUri getter. Actual open
# sites must no longer read the physical anchor URI directly.
open_region = job[job.index('Future<ByteResponse> _openRange'):]
forbid(open_region, 'session.id.canonicalUri', 'physical anchor URI in transport open path')

for token in (
    'final sourceId = claim.exactId;',
    'requestUri: sourceId.canonicalUri,',
    "'providerExactId': sourceId.key",
):
    require(owner, token, 'owner provider request identity projection')

pubspec = read('apps/app/pubspec.yaml')
props = read('apps/app/android/zic-version.properties')
pub = re.search(r'^version: \d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)$', pubspec, re.M)
android = re.search(r'^versionCode=(\d+)$', props, re.M)
if pub is None or int(pub.group(1)) < 227:
    raise SystemExit('dev.227 app version mismatch')
if android is None or int(android.group(1)) < 227:
    raise SystemExit('dev.227 Android version mismatch')
build = int(pub.group(1))
if build >= 239:
    require(owner, 'final taskTransport =', 'dev.239+ task transport selection')
    require(owner, 'provider.transportFor(sourceId.canonicalUri)', 'dev.239+ fallback provider exact URI')
    require(owner, 'transport: taskTransport,', 'dev.239+ selected task transport')
else:
    require(owner, 'transport: provider.transportFor(sourceId.canonicalUri),', 'owner provider exact transport projection')

for token in (
    'equivalent failed partial resumes through provider exact request URI',
    'registry.aliasPhysical(id: exact, target: physical);',
    'expect(uri, exact.canonicalUri);',
    'expect(session.state, DownloadState.failed);',
    'expect(session.state, DownloadState.promoted);',
    'expect(transport.openedUris, everyElement(exact.canonicalUri));',
):
    require(test, token, 'failed-partial provider identity behavior regression')

for rel in (
    'docs/archive/adr/0207-provider-exact-request-identity-after-physical-alias.md',
    'docs/archive/audits/dev227-provider-request-identity-root-cause-audit.md',
    'docs/archive/audits/dev227-validation-results.md',
):
    if not (ROOT / rel).exists():
        raise SystemExit(f'dev.227 missing governance: {rel}')

print('dev.227 provider request identity closure: OK')

#!/usr/bin/env python3
"""Guard dev.263 decode/upload physical-generation dependency coherence."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.263 contract: {missing}')

pubspec = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
if m is None or int(m.group(1)) < 263:
    raise SystemExit('App build must be >=263')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')

require(
    'packages/sessions/lib/src/upload_registry.dart',
    'int invalidateForDownload(DownloadId id)',
    '.where((decodeId) => decodeId.download == id)',
    '_sessions.remove(decodeId)?.dispose();',
)
require(
    'packages/sessions/lib/src/live_coordinator.dart',
    'upload.cancel(decodeId.key);',
    'final invalidatedUploads = uploads?.invalidateForDownload(id) ?? 0;',
    'final invalidatedDecodes = decodes?.invalidateForDownload(id) ?? 0;',
    "'invalidatedUploads': invalidatedUploads",
    "'invalidatedDecodes': invalidatedDecodes",
)
coordinator = read('packages/sessions/lib/src/live_coordinator.dart')
if coordinator.index('uploads?.invalidateForDownload(id)') > coordinator.index('decodes?.invalidateForDownload(id)'):
    raise SystemExit('UploadSession dependencies must invalidate before DecodeSession')
require(
    'packages/sessions/test/live_coordinator_test.dart',
    'logical source watch rebinds after aliased physical owner retires',
    'final oldUploadSession = uploads.find(decodeId);',
    'expect(uploader.outputs, hasLength(2));',
    'expect(reboundUploadSession, isNot(same(oldUploadSession)));',
)
for path in (
    'docs/archive/adr/0241-decode-upload-generation-coherence.md',
    'docs/archive/audits/dev263-decode-upload-generation-coherence-audit.md',
):
    if not (ROOT / path).is_file():
        raise SystemExit(f'missing dev.263 governance file: {path}')
require('tool/check.sh', 'test_dev263_decode_upload_generation_coherence.py')

# Frozen reader/network policy must remain intact.
require('packages/downloads/lib/src/download_resource_coordinator.dart', 'reservedHighPrioritySlots: 1')
if int(m.group(1)) >= 268:
    require('packages/sessions/lib/src/download_job.dart', ": 'pseudo-parked'", 'responseRetained: true')
else:
    require('packages/sessions/lib/src/download_job.dart', "'range-resume-unproven'")
print('dev.263 decode/upload generation coherence: OK')

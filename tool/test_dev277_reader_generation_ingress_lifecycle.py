#!/usr/bin/env python3
"""Guard dev.277 Reader generation/ingress/uploader lifecycle closure."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def text(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def req(ok: bool, message: str) -> None:
    if not ok:
        raise SystemExit(message)

def require(path: str, *needles: str) -> None:
    body = text(path)
    missing = [needle for needle in needles if needle not in body]
    req(not missing, f'{path} missing dev.277 contract: {missing}')

pub = text('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pub, re.M)
req(m is not None and int(m.group(1)) >= 277, 'dev.277 app version missing')
props = text('apps/app/android/zic-version.properties')
vm = re.search(r'^versionCode=(\d+)\s*$', props, re.M)
req(vm is not None and int(vm.group(1)) >= 277, 'dev.277 Android version missing')

registry = text('packages/sessions/lib/src/download_ingress_registry.dart')
req(
    'DownloadIngressProjection get(DownloadSession session) => attach(session);' in registry,
    'Reader ingress registry get() is not generation-aware',
)
req(
    '_entries[session.id]?.projection ?? attach(session)' not in registry,
    'old DownloadId-only ingress get path remains',
)

artifact = text('packages/storage/lib/src/artifact.dart')
for marker in (
    'Future<RandomAccessFile?> _openReadableDataFile() async',
    'for (final path in <String>[preferred, alternate])',
    'return await File(path).open(mode: FileMode.read);',
    'final reader = await _openReadableDataFile();',
):
    req(marker in artifact, f'Artifact promotion-read owner missing: {marker}')
req('_readableDataFile()' not in artifact, 'old exists-then-open artifact read helper remains')

session = text('packages/sessions/lib/src/download_session.dart')
for marker in (
    'final physicalBoundaryChanged =',
    'final projectionCaughtUp =',
    'replayed.length == targetLength',
    'replayed.sealed == sealed',
    'replayed.failure == null',
    'Reader ingress projection did not reach the authoritative physical boundary',
):
    req(marker in session, f'synchronized projection closure missing: {marker}')

upload = text('packages/sessions/lib/src/upload_session.dart')
dispose = upload[upload.index('  void dispose() {'):upload.index('  void _emitOutputReleased({')]
for marker in (
    '_releaseUploaderWhenIdle = false;',
    'uploader.release(id);',
):
    req(marker in dispose, f'generation dispose uploader retirement missing: {marker}')
req('_requestUploaderRelease();' not in dispose, 'generation dispose still defers uploader release')
# Ordinary detach/reset/frame-budget release semantics remain deliberately deferred.
req(upload.count('_requestUploaderRelease();') >= 3, 'ordinary deferred uploader release contract was removed')

require(
    'packages/storage/test/artifact_test.dart',
    'readers survive the sealed-to-promoted rename window',
)
require(
    'packages/sessions/test/download_session_test.dart',
    'late Reader replay survives artifact promotion path handoff',
    'Reader ingress registry replaces a retired same-id session generation',
)
require(
    'packages/sessions/test/upload_session_test.dart',
    'dispose retires a pending generation uploader slot immediately',
    'expect(uploader.released, <DecodeId>[decode.id]);',
)

for path in (
    'docs/adr/0255-reader-generation-ingress-and-uploader-retirement.md',
    'docs/audits/dev277-reader-reentry-ingress-generation-audit.md',
):
    req((ROOT / path).is_file(), f'missing dev.277 governance file: {path}')

require('docs/ARCHITECTURE.md', 'same DownloadId', 'generation retirement barrier')
require('docs/SPEC.md', 'same DownloadId的新physical session', 'promotion的data-file rename')
require('docs/IMPLEMENTATION_STATUS.md', 'SourceEpoch', 'frameUploaded', 'generation')
require('docs/NEXT_CHAT_HANDOFF.md', 'SourceEpoch', 'frameUploaded', 'generation')
require('CHANGELOG.md', '0.31.0-dev.277', 'generation')

print('PASS: dev.277 Reader generation ingress/uploader lifecycle closure')

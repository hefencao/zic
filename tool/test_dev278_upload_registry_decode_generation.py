#!/usr/bin/env python3
"""Guard dev.278 UploadRegistry -> DecodeSession generation binding."""
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
    req(not missing, f'{path} missing dev.278 contract: {missing}')

pub = text('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pub, re.M)
req(m is not None and int(m.group(1)) >= 278, 'dev.278 app version missing')
props = text('apps/app/android/zic-version.properties')
vm = re.search(r'^versionCode=(\d+)\s*$', props, re.M)
req(vm is not None and int(vm.group(1)) >= 278, 'dev.278 Android version missing')

registry = text('packages/sessions/lib/src/upload_registry.dart')
for marker in (
    'final decode = decodes.get(id);',
    'final existing = _sessions[id];',
    'identical(existing.decode, decode)',
    '_sessions.remove(id);',
    'existing.dispose();',
    'decode: decode,',
    '_sessions[id] = session;',
):
    req(marker in registry, f'UploadRegistry generation owner missing: {marker}')
req(
    'return _sessions.putIfAbsent(id, () {' not in registry,
    'logical DecodeId-only UploadRegistry get path remains',
)

# UploadSession remains fixed-generation: registry retirement/recreation is the
# repair, not dynamic dependency lookup inside UploadSession.
upload = text('packages/sessions/lib/src/upload_session.dart')
require('packages/sessions/lib/src/upload_session.dart', 'final DecodeSession decode;')
req('decodes.get(id)' not in upload, 'UploadSession dynamically looks up DecodeRegistry')

require(
    'packages/sessions/test/live_coordinator_test.dart',
    'upload registry replaces a stale concrete decode generation binding',
    'expect(firstUpload.state, UploadState.disposed);',
    'expect(replacementUpload.decode, same(replacementDecode));',
)

for path in (
    'docs/archive/adr/0256-upload-registry-decode-generation-binding.md',
    'docs/archive/audits/dev278-reader-reentry-upload-generation-audit.md',
):
    req((ROOT / path).is_file(), f'missing dev.278 governance file: {path}')

require('docs/ARCHITECTURE.md', 'UploadRegistry拥有UploadSession→DecodeSession concrete-generation binding不变量')
require('docs/SPEC.md', 'UploadRegistry MUST把logical DecodeId与concrete DecodeSession generation区分')
require('docs/IMPLEMENTATION_STATUS.md', 'SourceEpoch', 'decode/upload', 'generation')
require('docs/NEXT_CHAT_HANDOFF.md', 'SourceEpoch', 'framePresented', 'generation')
require('CHANGELOG.md', '0.31.0-dev.278', 'DecodeSession generation')

print('PASS: dev.278 UploadRegistry concrete DecodeSession generation binding')

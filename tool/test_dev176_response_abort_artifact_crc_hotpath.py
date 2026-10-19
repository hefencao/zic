#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'missing {label}: {token}')

def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'superseded {label}: {token}')

transport = read('packages/downloads/lib/src/source_resource_transport.dart')
for token in (
    'taskControl.whenCancelled.then((_) => body.abort())',
    'if (!completed) {',
    'await _abort();',
    'Stream<List<int>> get stream async*',
):
    require(transport, token, 'response lifetime cancellation')

artifact = read('packages/storage/lib/src/artifact.dart')
for token in (
    'bool _checksumDirty = false;',
    "String get checksum => _checksumDirty ? '' : _crc.hex;",
    'if (_checksumDirty) {',
    'await _rehash(File(partialPath));',
    'final result = await Isolate.run<(int, String)>',
    '_checksumDirty = true;',
):
    require(artifact, token, 'artifact checksum boundary')
append_start = artifact.index('Future<void> _append(')
append_end = artifact.index('Future<void> flush()', append_start)
forbid(artifact[append_start:append_end], '_crc.add(', 'CRC in append hot path')

transport_test = read('packages/downloads/test/source_resource_transport_test.dart')
require(
    transport_test,
    'controlled cancellation aborts an already streaming host response',
    'stream cancellation regression test',
)
artifact_test = read('packages/storage/test/artifact_test.dart')
require(
    artifact_test,
    'partial append defers crc until seal outside the download hot path',
    'deferred CRC regression test',
)

check = read('tool/check.sh')
require(check, 'test_dev176_response_abort_artifact_crc_hotpath.py', 'release gate wiring')

version = re.search(r'^version:\s*\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if version is None or int(version.group(1)) < 176:
    raise SystemExit('App build must be at least 176')
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.176 response abort + artifact CRC hot-path contract: OK')

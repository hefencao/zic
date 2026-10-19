#!/usr/bin/env python3
"""Guard dev.250 ByteResponse flow-control public API closure."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.250 API closure: {missing}')

pubspec = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)\s*$', pubspec, re.M)
if m is None or int(m.group(1)) < 250:
    raise SystemExit('App build must be >=250')
build = int(m.group(1))
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')

transport = read('packages/transport/lib/src/transport.dart')
for token in (
    'enum ByteResponseFlowControl',
    'this.flowControl = ByteResponseFlowControl.none',
    'final ByteResponseFlowControl flowControl;',
):
    if token not in transport:
        raise SystemExit(f'transport ByteResponse API is not closed: {token}')
if transport.count('final ByteResponseFlowControl flowControl;') != 1:
    raise SystemExit('ByteResponse flowControl must have exactly one typed instance field')

require(
    'packages/downloads/lib/downloads.dart',
    'ByteResponse, ByteResponseFlowControl, ByteResponseReadDiagnostics, Validators',
)
# Bridge intentionally stays behind downloads facade rather than adding a
# transport package import just for the enum.
bridge = read('packages/downloads_bridge/lib/src/rhttp_source_resource_transport.dart')
if "import 'package:transport/" in bridge:
    raise SystemExit('downloads_bridge must not add a second direct transport dependency')
for path in (
    'packages/transport/lib/src/io_transport.dart',
    'packages/downloads/lib/src/source_resource_transport.dart',
):
    require(path, 'ByteResponseFlowControl.streamBackpressure')
if build >= 252:
    require(
        'packages/downloads_bridge/lib/src/rhttp_source_resource_transport.dart',
        'ByteResponseFlowControl.consumerPacing',
    )
else:
    require(
        'packages/downloads_bridge/lib/src/rhttp_source_resource_transport.dart',
        'ByteResponseFlowControl.streamBackpressure',
    )
for path in (
    'packages/downloads/lib/src/artifact_cache_transport.dart',
    'packages/downloads/lib/src/source_resource_transport.dart',
):
    require(path, 'flowControl: response.flowControl')
if build >= 251:
    require(
        'packages/sessions/lib/src/download_job.dart',
        'response.flowControl != ByteResponseFlowControl.none',
        'capability: response.flowControl',
    )
else:
    require(
        'packages/sessions/lib/src/download_job.dart',
        'response.flowControl == ByteResponseFlowControl.streamBackpressure',
    )
require('tool/check.sh', 'test_dev250_byte_response_flow_control_api_closure.py')
print('dev.250 ByteResponse flow-control API closure: OK')

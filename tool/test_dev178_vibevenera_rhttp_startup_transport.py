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
        raise SystemExit(f'forbidden {label}: {token}')

core = read('packages/downloads/lib/src/source_resource_transport.dart')
for token in (
    'abstract interface class SourceResourceDirectTransport',
    'TaskControl? control,',
    'SourceResourceDirectTransport? directTransport,',
    'directTransport.open(',
    'control: control,',
    '_directTransport?.close();',
):
    require(core, token, 'controlled platform direct transport contract')
forbid(core, "package:rhttp", 'rhttp dependency in pure downloads core')

bridge_pubspec = read('packages/downloads_bridge/pubspec.yaml')
downloads_public = read('packages/downloads/lib/downloads.dart')
require(bridge_pubspec, 'rhttp: 0.13.0', 'Dart 3.6-compatible rhttp pin')
bridge = read('packages/downloads_bridge/lib/src/rhttp_source_resource_transport.dart')
for token in (
    'implements SourceResourceDirectTransport',
    'prewarmPlatformSourceResourceTransport()',
    'rhttp.Rhttp.init()',
    'rhttp.RhttpClient.create(',
    'rhttp.RedirectSettings.none()',
    'keepAliveTimeout: Duration(seconds: 60)',
    'client.requestStream(',
    'final cancelToken = rhttp.CancelToken();',
    'taskControl.whenCancelled.then((_) => cancelToken.cancel())',
    'sourceMediaProtocolMismatch',
    '_prefetchEncodedMediaBody(',
):
    require(bridge, token, 'rhttp streaming transport invariant')

home = read('apps/app/lib/demo_home.dart')
require(home, 'directTransport: RhttpSourceResourceDirectTransport()',
        'production source transport injection')
main = read('apps/app/lib/main.dart')
require(main, 'prewarmPlatformSourceResourceTransport()',
        'background rhttp native prewarm')

test = read('packages/downloads/test/source_resource_transport_test.dart')
for token in (
    'platform direct transport receives the same scheduler control',
    'implements SourceResourceDirectTransport',
    'expect(identical(direct.lastControl, control), isTrue);',
):
    require(test, token, 'scheduler-control regression coverage')

# Do not "fix" startup by shrinking the VibeVenera-derived working sets.
policy = read('packages/pipeline/lib/src/stable_preload_policy.dart') if (ROOT / 'packages/pipeline/lib/src/stable_preload_policy.dart').exists() else ''
if policy:
    for token in ('downloadNext', 'downloadPrev'):
        require(policy, token, 'stable preload policy ownership')

version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if version is None or version.group(1) != '178' or android is None or android.group(1) != '178':
    raise SystemExit('dev.178 version mismatch')


for token in (
    "export 'package:catalog/catalog.dart' show ComicResourceRequest;",
    "export 'package:domain/domain.dart' show ErrorCode, Failure, TaskControl;",
    "export 'package:transport/transport.dart' show ByteResponse, Validators;",
):
    require(downloads_public, token, 'downloads public direct-transport type surface')
for forbidden in ("package:catalog/catalog.dart", "package:domain/domain.dart", "package:transport/transport.dart"):
    if forbidden in bridge:
        raise SystemExit(f'downloads_bridge bypasses downloads capability surface: {forbidden}')
for forbidden_dep in ('  catalog:', '  domain:', '  transport:'):
    if forbidden_dep in bridge_pubspec:
        raise SystemExit(f'downloads_bridge adds forbidden internal dependency: {forbidden_dep.strip()}')

print('dev.178 VibeVenera rhttp startup transport contract: OK')

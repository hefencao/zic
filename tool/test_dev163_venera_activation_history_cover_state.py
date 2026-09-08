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

runtime = read('packages/plugin_host_bridge/lib/src/method_channel_runtime_backends.dart')
# dev.164 supersedes the dev.163 Dart activation replay: initial Binder
# generation continuity now belongs to the Android runtime-service client.
for stale in (
    'const Set<String> _recoverableActivationRuntimeCodes',
    'if (!_recoverableActivationRuntimeCodes.contains(error.code))',
):
    forbid(runtime, stale, 'Dart-owned initial activation replay')

client = read(
    'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/'
    'PluginRuntimeServiceClient.kt'
)
policy = read(
    'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/'
    'RuntimeServiceRequestLifecyclePolicy.kt'
)
for token in (
    'replayInitialActivationsAfterServiceLoss',
    'serviceGenerationReplays += 1',
    'RuntimeServiceRequestLifecyclePolicy',
):
    require(client, token, 'Android-owned initial activation continuity')
for token in (
    '"activateVeneraRuntime"',
    '"activateMihonRuntime"',
    '"runtime-service-died"',
    '"runtime-service-disconnected"',
    'completedReplays == 0',
):
    require(policy, token, 'bounded service-generation policy')

runtime_test = read('packages/plugin_host_bridge/test/method_channel_runtime_backends_test.dart')
require(
    runtime_test,
    'Venera backend leaves service-generation recovery to Android',
    'Venera activation ownership test',
)
require(
    runtime_test,
    'Venera activation does not replay plugin activation errors',
    'non-retry business-error test',
)

views = read('apps/app/lib/demo_home_views.dart')
for token in (
    "final section = history ? 'home-history' : 'home-update';",
    'final presentationIdentities = <String>[',
    'key: ValueKey<String>(presentationIdentity)',
    'findChildIndexCallback: (key)',
    'return itemIndex == null ? null : itemIndex * 2;',
    'telemetryIdentity: presentationIdentity',
    'sourceAvailable: _coverSourceAvailableForComic(comic)',
):
    require(views, token, 'history/update cover state identity')
forbid(views, "key: ValueKey<String>(\n                '${history ? 'home-history' : 'home-update'}:$coverIdentity'", 'nested-only cover list key')


home = read('apps/app/lib/demo_home.dart')
for token in (
    'bool _coverSourceAvailableForComic(LibraryComic comic)',
    "comic.sourceId == 'local-folder' || _sourceForId(comic.sourceId) != null",
):
    require(home, token, 'explicit source-availability dependency')

library_test = read('apps/app/test/library_ui_test.dart')
require(
    library_test,
    'cover reloads a failed source only when the source becomes available',
    'cover source-ready transition test',
)

widgets = read('apps/app/lib/home_widgets.dart')
for token in (
    'final String? telemetryIdentity;',
    'coverSourceFailed(',
    'errorType: error.runtimeType.toString()',
    'final telemetryIdentity = widget.telemetryIdentity;',
    '_loadTelemetryIdentity = telemetryIdentity;',
    '_loadTelemetry?.coverDecodeFailed(identity);',
    'final sourceAvailableAtStart = widget.sourceAvailable;',
    'sourceAvailable: sourceAvailableAtStart',
    'final sourceBecameAvailable =',
    'if (cacheChanged || (_sourceFailed && sourceBecameAvailable))',
    'onDecodeFailure: _reportDecodeFailure',
):
    require(widgets, token, 'cover failure observability')
for stale in ('Timer(', '.evict()', 'ArtworkRetryController', 'RecoverableArtworkImage'):
    forbid(widgets, stale, 'presentation-owned artwork recovery')

trace = read('packages/telemetry/lib/src/trace.dart')
require(trace, 'homeCoverSourceFailed', 'source failure trace event')
require(trace, 'homeCoverDecodeFailed', 'decode failure trace event')

version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 163:
    raise SystemExit('App build must be at least 163')
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.163 Venera activation + history cover state boundary: OK')

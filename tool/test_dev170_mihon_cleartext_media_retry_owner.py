#!/usr/bin/env python3
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
ANDROID_NS = '{http://schemas.android.com/apk/res/android}'

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'missing {label}: {token}')

def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'superseded {label}: {token}')

manifest_path = ROOT / 'apps/app/android/app/src/main/AndroidManifest.xml'
network_path = ROOT / 'apps/app/android/app/src/main/res/xml/network_security_config.xml'
manifest = ET.parse(manifest_path).getroot()
application = manifest.find('application')
if application is None:
    raise SystemExit('Android application manifest entry is missing')
if application.get(ANDROID_NS + 'networkSecurityConfig') != '@xml/network_security_config':
    raise SystemExit('Android app must bind the shared network security config')
if application.get(ANDROID_NS + 'usesCleartextTraffic') != 'true':
    raise SystemExit('Android app must preserve pre-network-security-config cleartext compatibility')
network = ET.parse(network_path).getroot()
base = network.find('base-config')
if base is None or base.get('cleartextTrafficPermitted') != 'true':
    raise SystemExit('generic Mihon media transport must permit source-owned cleartext URLs')
network_text = read('apps/app/android/app/src/main/res/xml/network_security_config.xml').lower()
for domain in ('wnimg1', 'wnacg', 'wn09.shop'):
    forbid(network_text, domain, 'source-specific cleartext domain allowlist')

adapter = read('packages/plugin_host/lib/src/runtime_source_adapter.dart')
for token in (
    'runtimeError.retryable',
    '? ErrorCode.network',
    "'runtimeErrorCode': runtimeError.code",
    "'runtimeRetryable': runtimeError.retryable",
):
    require(adapter, token, 'runtime retryability propagation')

mihon = read('packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt')
require(mihon, 'val networkFailure = error.isNetworkFailure()', 'original-chain network classification')
require(mihon, 'if (current is java.net.UnknownServiceException) return false', 'deterministic network-policy classification')

coordinator = read('packages/sessions/lib/src/live_coordinator.dart')
transfer_owner_path = ROOT / 'packages/sessions/lib/src/download_transfer_owner.dart'
physical_owner = (transfer_owner_path.read_text(encoding='utf-8')
                  if transfer_owner_path.exists() else coordinator)
for token in (
    'final Set<DownloadId> _downloadTerminalFailures',
    '_downloadTerminalFailures.contains(id)',
    '_downloadTerminalFailures.add(id)',
    'bool _scheduleDownloadRetry(',
    'return false;',
    'return true;',
):
    require(physical_owner, token, 'single-owner terminal download retry contract')
# Source snapshots may wake decode, but must not own a second download retry path.
watch_start = coordinator.index('  void _watchSource(')
watch_end = coordinator.index('  void _reconcileDecodes(', watch_start)
watch = coordinator[watch_start:watch_end]
forbid(watch, '_ensureDownloadTask(', 'source-listener download resubmission')
forbid(watch, '_scheduleDownloadRetry(', 'source-listener retry ownership')

source_browser = read('apps/app/lib/source_browser.dart')
for token in (
    "if (error is Failure) 'errorCode': error.code.name",
    "if (error is Failure) 'errorMessage': error.message",
):
    require(source_browser, token, 'source-cover failure diagnostics')

session_test = read('packages/sessions/test/live_coordinator_test.dart')
require(session_test, 'terminal source failure survives scheduling-only demand changes', 'terminal failure regression test')
transfer_owner_test = read('packages/sessions/test/download_transfer_owner_test.dart')
require(
    transfer_owner_test,
    'provider setup failures retry finitely and publish terminal failure',
    'physical owner finite retry regression test',
)
require(
    transfer_owner_test,
    "reason: 'unchanged demand must not hot-loop'",
    'physical owner unchanged-demand regression assertion',
)
plugin_test = read('packages/plugin_host/test/runtime_source_adapter_test.dart')
require(plugin_test, 'maps retryable runtime failure to a typed network failure', 'runtime retryability regression test')

version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 170:
    raise SystemExit('App build must be at least 170')
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.170 Mihon cleartext media + terminal retry ownership: OK')

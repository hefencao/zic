#!/usr/bin/env python3
"""Guard dev.198 product-safe rhttp endpoint diagnostics and opt-in progress."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = (ROOT / 'packages/downloads_bridge/lib/src/rhttp_source_resource_transport.dart').read_text(encoding='utf-8')
BUILD = (ROOT / 'tool/build_android.sh').read_text(encoding='utf-8')
ANALYZER = (ROOT / 'tool/analyze_frame_pipeline_trace.py').read_text(encoding='utf-8')
SPEC = (ROOT / 'docs/SPEC.md').read_text(encoding='utf-8')
STATUS = (ROOT / 'docs/IMPLEMENTATION_STATUS.md').read_text(encoding='utf-8')
HANDOFF = (ROOT / 'docs/NEXT_CHAT_HANDOFF.md').read_text(encoding='utf-8')
CHANGELOG = (ROOT / 'CHANGELOG.md').read_text(encoding='utf-8')

for token in (
    "bool.fromEnvironment('ZIC_RHTTP_RECEIVE_PROGRESS_DIAGNOSTICS')",
    "!bool.fromEnvironment('dart.vm.product')",
    "'sourceHostHttpVersion': _httpVersionName(response.version)",
    "'sourceHostRemoteIpHash': _stableDiagnosticHash(response.remoteIp!)",
    "'sourceRhttpReceiveProgressEnabled':",
    'onReceiveProgress: readDiagnostics?.recordReceiveProgress',
):
    if token not in BRIDGE:
        raise SystemExit(f'dev.198 rhttp diagnostic boundary missing: {token}')

# Default product/release must not force the high-frequency progress callback.
if "_rhttpReceiveProgressDiagnosticsRequested =\n    bool.fromEnvironment('ZIC_RHTTP_RECEIVE_PROGRESS_DIAGNOSTICS');" not in BRIDGE:
    raise SystemExit('dev.198 product progress diagnostics are not explicit opt-in')

for token in (
    'ZIC_RHTTP_RECEIVE_PROGRESS_DIAGNOSTICS',
    '--dart-define=ZIC_RHTTP_RECEIVE_PROGRESS_DIAGNOSTICS=true',
    'RHTTP_RECEIVE_DIAGNOSTICS="${ZIC_RHTTP_RECEIVE_PROGRESS_DIAGNOSTICS:-0}"',
):
    if token not in BUILD:
        raise SystemExit(f'dev.198 Android diagnostic build switch missing: {token}')

for token in ('sourceRhttpRemoteIpHashCounts', 'sourceRhttpReceiveProgressEnabledCounts'):
    if token not in ANALYZER:
        raise SystemExit(f'dev.198 trace analyzer grouping missing: {token}')

# Diagnostics remain observation-only and must not become policy inputs.
for relative in ('packages/sessions/lib', 'packages/pipeline_runtime/lib', 'apps/app/lib'):
    for path in (ROOT / relative).rglob('*.dart'):
        body = path.read_text(encoding='utf-8')
        if 'sourceRhttpRemoteIpHashCounts' in body or 'ZIC_RHTTP_RECEIVE_PROGRESS_DIAGNOSTICS' in body:
            raise SystemExit(
                f'dev.198 transport diagnostics leaked into policy layer: {path.relative_to(ROOT)}'
            )

for token in (
    '匿名 remote-IP hash',
    'ZIC_RHTTP_RECEIVE_PROGRESS_DIAGNOSTICS',
    '默认关闭',
):
    if token not in SPEC:
        raise SystemExit(f'dev.198 stable diagnostic boundary missing from spec: {token}')

pubspec = (ROOT / 'apps/app/pubspec.yaml').read_text(encoding='utf-8')
properties = (ROOT / 'apps/app/android/zic-version.properties').read_text(encoding='utf-8')
app = re.search(r'^version: 0\.31\.0\+(\d+)$', pubspec, re.MULTILINE)
android = re.search(r'^versionCode=(\d+)$', properties, re.MULTILINE)
if app is None or int(app.group(1)) < 198:
    raise SystemExit('dev.198-or-newer app build missing')
if android is None or int(android.group(1)) < 198:
    raise SystemExit('dev.198-or-newer Android version missing')

for body, name in ((STATUS, 'status'), (HANDOFF, 'handoff'), (CHANGELOG, 'changelog')):
    if 'dev.198' not in body:
        raise SystemExit(f'dev.198 missing from {name}')

for path in (
    ROOT / 'docs/adr/0179-product-safe-rhttp-endpoint-diagnostics.md',
    ROOT / 'docs/audits/dev198-rhttp-endpoint-diagnostics-root-cause-audit.md',
    ROOT / 'docs/audits/dev198-validation-results.md',
):
    if not path.exists():
        raise SystemExit(f'dev.198 release document missing: {path.relative_to(ROOT)}')

print('dev.198 product-safe rhttp endpoint diagnostics: OK')

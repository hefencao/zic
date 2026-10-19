#!/usr/bin/env python3
"""Guard dev.279 continuity after its lifecycle-checkpoint supersession."""
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
    req(not missing, f'{path} missing dev.279 contract: {missing}')

pub = text('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)\s*$', pub, re.M)
req(m is not None and int(m.group(1)) >= 279, 'dev.279 app version missing')
props = text('apps/app/android/zic-version.properties')
vm = re.search(r'^versionCode=(\d+)\s*$', props, re.M)
req(vm is not None and int(vm.group(1)) >= 279, 'dev.279 Android version missing')

ingress = text('packages/sessions/lib/src/download_ingress_registry.dart')
for marker in (
    'existing.attachment == null',
    'snapshot.sealed',
    'snapshot.sourceReady',
    'snapshot.failure == null',
    'existing.session = session;',
    '!identical(entry.session, session)',
):
    req(marker in ingress, f'sealed Reader generation owner missing: {marker}')

coordinator = text('packages/sessions/lib/src/live_coordinator.dart')
for marker in (
    "'sealed-source-generation-preserved'",
    "'invalidatedUploads': 0",
    "'invalidatedDecodes': 0",
    'identical(existing.projection, projection)',
):
    req(marker in coordinator, f'LiveCoordinator sealed generation continuity missing: {marker}')
# Strict physical-generation invalidation must remain for actual projection change.
for marker in (
    "'physical-generation-changed'",
    'uploads?.invalidateForDownload(id)',
    'decodes?.invalidateForDownload(id)',
):
    req(marker in coordinator, f'strict physical-generation rebind removed: {marker}')

require(
    'packages/sessions/test/download_session_test.dart',
    'Reader ingress registry preserves sealed same-id encoded generation',
    'expect(secondProjection, same(firstProjection));',
    'ingresses.detach(firstSession);',
    'expect(ingresses.find(id), same(secondProjection));',
)

runtime = text('packages/downloads/lib/src/composition_download_transfer_runtime.dart')
for marker in (
    'Future<void> checkpointPartials({',
    "String reason = 'runtime-safety-checkpoint'",
    'await handoff.persist(session, reason: reason);',
    'EphemeralCacheWorkspace.readerSession(',
):
    req(marker in runtime, f'composition partial checkpoint missing: {marker}')

app = text('apps/app/lib/main.dart') + text('apps/app/lib/app_runtime.dart')
for marker in (
    'checkpointTransferPartials()',
    "checkpointPartials(reason: 'app-runtime-safety-checkpoint')",
    'await checkpointTransferPartials();',
    'requestAndroidApplicationBackground()',
):
    req(marker in app, f'app runtime safety/background contract missing: {marker}')
lifecycle_start = app.index('void didChangeAppLifecycleState(AppLifecycleState state)')
lifecycle_end = app.index('Future<void> _recordLifecycleSchedulingSnapshot(', lifecycle_start)
lifecycle_body = app[lifecycle_start:lifecycle_end]
for forbidden in (
    'checkpointTransferPartials(',
    'checkpointPartials(',
    "'app-lifecycle-checkpoint'",
):
    req(forbidden not in lifecycle_body,
        f'ordinary lifecycle observation still checkpoints partial: {forbidden}')
req("checkpointPartials(reason: 'app-lifecycle-checkpoint')" not in app,
    'obsolete app-lifecycle checkpoint reason remains')

workspace = text('packages/storage/lib/src/ephemeral_workspace.dart')
for marker in (
    'factory EphemeralCacheWorkspace.recoverableTransfer(String stableId)',
    "'zic-transfer-$safeId'",
):
    req(marker in workspace, f'recoverable transfer staging missing: {marker}')
downloads = text('packages/downloads/lib/src/chapter_downloads.dart')
req(
    'transferWorkspace: EphemeralCacheWorkspace.recoverableTransfer(root)' in downloads,
    'production composition must inject recoverable app-private staging',
)

require(
    'packages/downloads/test/physical_transfer_retention_test.dart',
    'explicit runtime checkpoint persists hot partial without retiring owner',
    'expect(runtime.registry.findExact(id), same(session));',
    'expect(session.state, DownloadState.receiving);',
    'expect(session.hasWriter, isTrue);',
)
require(
    'packages/downloads/test/partial_download_handoff_test.dart',
    'replacement runtime restores recoverable app-private partial before network',
    "reason: 'restart recovery must not depend on durable partial handoff'",
    'expect(transport.rangeStarts, <int>[prefixLength]);',
)

for path in (
    'docs/archive/adr/0257-sealed-reader-encoded-generation-continuity.md',
    'docs/archive/adr/0258-app-lifecycle-durable-partial-checkpoint.md',
    'docs/archive/adr/0307-recoverable-transfer-staging-root-background.md',
    'docs/archive/audits/dev279-local-reentry-cold-partial-regression-audit.md',
):
    req((ROOT / path).is_file(), f'missing dev.279 governance file: {path}')

require('docs/ARCHITECTURE.md', 'physical object generation与Reader encoded generation边界', 'recoverable transfer workspace')
require('docs/SPEC.md', 'physical object generation与Reader encoded generation', 'recoverable staging root')
require('docs/IMPLEMENTATION_STATUS.md', 'SourceEpoch', 'recoverable canonical partial', 'media-empty')
require('CHANGELOG.md', '0.31.0-dev.279', 'lifecycle partial checkpoint')

print('PASS: dev.279 continuity + recoverable staging/background supersession')

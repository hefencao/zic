#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(body: str, marker: str, message: str) -> None:
    if marker not in body:
        raise SystemExit(f'{message}: {marker}')


session = read('packages/sessions/lib/src/download_session.dart')
owner = read('packages/sessions/lib/src/download_transfer_owner.dart')
retention = read('packages/downloads/lib/src/physical_transfer_retention.dart')
partial_handoff = read('packages/downloads/lib/src/partial_download_handoff.dart')
workspace = read('packages/storage/lib/src/ephemeral_workspace.dart')
storage_spec = read('docs/DOWNLOAD_STORAGE_SPEC.md')

for marker in (
    'Future<void> dispose({bool discardOwnedArtifactBody = false})',
    'discardOwnedArtifactBody &&',
    '_borrowedBackingRelease == null',
    '!_residentBodyBacked',
    'await artifact.deleteAll();',
):
    require(session, marker, 'session-owned staging retirement boundary missing')

for marker in (
    'bool discardOwnedArtifactBody = false,',
    'discardOwnedArtifactBody: discardOwnedArtifactBody',
):
    require(owner, marker, 'mechanical physical retirement lost explicit discard intent')

if retention.count('discardOwnedArtifactBody: true') < 2:
    raise SystemExit('both promoted and partial pressure retirement must release owned hot staging')
for marker in (
    'if (handoff == null || !await handoff.settleAutomatic(session))',
    '!await handoff.persist(',
):
    require(retention, marker, 'hot staging may be discarded before durable handoff succeeds')

for marker in (
    'preferDirectStaging: true',
    'Mutable transfer checkpoints prefer App-private Direct staging.',
):
    require(partial_handoff, marker, 'transfer checkpoint policy moved onto provider hot path')

for marker in (
    'factory EphemeralCacheWorkspace.recoverableTransfer(String stableId)',
    "'zic-transfer-$safeId'",
):
    require(workspace, marker, 'recoverable transfer staging lost deterministic App-private root')

require(
    storage_spec,
    'On pure SAF roots, automatic cache and mutable partials SHOULD remain in App-private storage',
    'SAF partial staging contract unexpectedly moved provider-side',
)

print('download partial staging ownership: OK')

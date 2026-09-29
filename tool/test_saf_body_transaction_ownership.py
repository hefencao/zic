#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
artifact = (ROOT / 'packages/downloads/lib/src/artifact_bytes.dart').read_text()
store = (ROOT / 'packages/downloads/lib/src/persistent_download_artifact_store.dart').read_text()
structured = (ROOT / 'packages/downloads/lib/src/persistent_download_structured_placement.dart').read_text()
body = (ROOT / 'packages/downloads/lib/src/persistent_download_saf_body_transaction.dart').read_text()
downloads = (ROOT / 'packages/downloads/lib/downloads.dart').read_text()
app_runtime = (ROOT / 'apps/app/lib/app_runtime.dart').read_text()
saf_store = (ROOT / 'apps/app/lib/saf_store.dart').read_text()
android = (ROOT / 'apps/app/android/app/src/main/kotlin/dev/zic/zic/MainActivity.kt').read_text()

errors = []

def require(source, needle, message):
    if needle not in source:
        errors.append(message)

def forbid(source, needle, message):
    if needle in source:
        errors.append(message)

for source, label in [
    (artifact, 'artifact_bytes'),
    (downloads, 'downloads export'),
    (app_runtime, 'app runtime'),
    (saf_store, 'SAF store'),
    (android, 'Android bridge'),
]:
    forbid(source, 'SafTreeAtomicReplace', f'{label} still exposes SafTreeAtomicReplace')
for source, label in [(saf_store, 'SAF store'), (android, 'Android bridge')]:
    forbid(source, 'safReplace', f'{label} still exposes hidden safReplace mutation')

require(
    artifact,
    "SAF staged commit requires an unused target",
    'low-level SAF commit must remain create-only',
)
for forbidden in ['await io.delete(targetPath)', 'atomic.replace(temporaryPath, targetPath)']:
    block_start = artifact.find('Future<void> commitSafTemporary(')
    block_end = artifact.find('\n}\n', block_start) + 3
    if block_start < 0 or forbidden in artifact[block_start:block_end]:
        errors.append(f'commitSafTemporary still contains overwrite path: {forbidden}')

require(body, "Directory('$_metadataOwnerKey.saf-body-transactions')",
        'body transaction intent must remain App-private beside metadata owner')
require(body, 'await _writeSafBodyTransactionIntent(intent);',
        'body replace must persist intent before provider mutation')
intent = body.find('await _writeSafBodyTransactionIntent(intent);')
backup = body.find('io.rename(targetPath, backupPath)', intent)
install = body.find('io.rename(temporaryPath, targetPath)', intent)
commit = body.find('result = await commitAuthority();', intent)
if not (0 <= intent < backup < install < commit):
    errors.append('body replace order must be intent -> backup -> install -> index authority')
forbid(body, 'current.touchedUs == expected.touchedUs',
       'mutable touchedUs must not be SAF body commit evidence')
require(body, 'current.checksum == expected.checksum',
        'same-path partial commit proof must include checksum')
require(store, 'await resolved._recoverSafBodyTransactions();',
        'startup must recover body intents')
recover = store.find('await resolved._recoverSafBodyTransactions();')
cleanup = store.find('resolved._scheduleCleanupDebtDrain();', recover)
if not (0 <= recover < cleanup):
    errors.append('body intent recovery must run before cleanup-debt scheduling')
require(store, '_activeTemporaryCleanupLocators.contains(debt.accessLocator)',
        'live temp must be protected from background orphan cleanup')
require(store, '_commitSafBodyReplacement<void>(',
        'partial body commits must use durable body transaction')
require(structured, '_commitSafBodyReplacement<void>(',
        'READY SAF page replacement must use durable body transaction')
require(structured, '_commitSafManifestAndPlacement(',
        'manifest transaction must remain a separate placement protocol')
forbid(body, '_persistPlacement',
       'body transaction must not depend on DownloadPlacement commit tokens')

if errors:
    for error in errors:
        print(f'FAIL: {error}')
    raise SystemExit(1)
print('SAF body replacement transaction ownership: OK')

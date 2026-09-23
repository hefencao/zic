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

handoff = read('packages/downloads/lib/src/partial_download_handoff.dart')
require(handoff, "import 'package:domain/domain.dart';", 'DownloadId import ownership')
require(handoff, "import 'package:transport/transport.dart';", 'Validators import ownership')
for token in (
    'typedef PartialEquivalentCandidates = Iterable<DownloadId> Function(',
    'DownloadId id,',
    'final PartialEquivalentCandidates? equivalentCandidates;',
    'store.openPartialDownload(id)',
    'for (final equivalent in candidates(id)) {',
    'if (selected == null || entry.length > selected.entry.length)',
    '? const Validators()',
    "action: candidate.equivalent ? 'restored-equivalent' : 'restored'",
    "'verifiedEquivalentReuse': true",
):
    require(handoff, token, 'equivalence-aware durable partial restore')

runtime = read('packages/downloads/lib/src/composition_download_transfer_runtime.dart')
require(runtime, 'equivalentCandidates: _verifiedEquivalentCandidates,', 'composition proof injection')

migration = read('apps/app/lib/home_shell_source_migration.dart')
home = read('apps/app/lib/home_shell.dart')
reuse = read('packages/downloads/lib/src/artifact_cache_reuse.dart')
forbid(migration, '_reuseSourceVersionDurablePartials', 'version-warmup partial copy')
forbid(migration, "'stage': 'version-durable-partial-reused'", 'legacy partial-copy trace')
forbid(home, '_reuseSourceVersionDurablePartials', 'pre-Reader partial copy')
forbid(reuse, 'applyDurablePartials', 'reuse-plan partial copy')

test = read('packages/downloads/test/partial_download_handoff_test.dart')
for token in (
    'verified equivalent cold partial restores without copying exact entry',
    'longer verified equivalent cold partial outranks shorter exact',
    'equal verified cold partial keeps exact target authority',
    'expect(session.validators.isEmpty, isTrue);',
    'expect(backend.partial.containsKey(newId), isFalse);',
    'expect(backend.partial.containsKey(oldId), isTrue);',
):
    require(test, token, 'cold partial restore behavioral regression')

check = read('tool/check.sh')
require(check, 'test_dev229_equivalence_aware_cold_partial_restore.py', 'release gate wiring')

version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 229:
    raise SystemExit('App build must be at least 229')
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.229 equivalence-aware cold partial restore: OK')

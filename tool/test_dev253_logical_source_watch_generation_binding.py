#!/usr/bin/env python3
"""Guard dev.253 logical source-watch / physical-generation closure."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.253 contract: {missing}')


def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    if present:
        raise SystemExit(f'{path} contains superseded dev.253 shape: {present}')


pubspec = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
if m is None or int(m.group(1)) < 253:
    raise SystemExit('App build must be >=253')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')

require(
    'packages/sessions/lib/src/live_coordinator.dart',
    'final class _SourceWatchBinding',
    'final Map<DownloadId, _SourceWatchBinding> _sourceWatches',
    '_sourceWatches[id]?.projection.snapshot.revision',
    'identical(existing.session, session)',
    'identical(existing.projection, projection)',
    'existing.projection.removeSourceListener(existing.listener)',
    '_sourceRevisions.remove(id)',
    '_sourceWakeLengths.remove(id)',
    'decode.cancel(decodeId.key)',
    'decodes?.invalidateForDownload(id)',
    '_sourceRebindWakes.add(id)',
    "'stage': 'reader-source-watch-rebind'",
    "'action': 'physical-generation-changed'",
    '_flushSourceRebindWakes(sessionId)',
)
reject(
    'packages/sessions/lib/src/live_coordinator.dart',
    'final Map<DownloadId, SourceListener> _sourceListeners',
    '_sourceListeners.containsKey(id)',
)

require(
    'packages/sessions/lib/src/download_ingress_registry.dart',
    'identical(existing.session, session)',
    'existing.session.detachIngressProjection(existing.projection.scopeId)',
    'existing.projection.detach()',
    'sources.remove(session.id)',
    'new physical DownloadSession with the same DownloadId is a new',
)
require(
    'packages/sessions/lib/src/decode_registry.dart',
    'int invalidateForDownload(DownloadId id)',
    'decodeId.download == id',
    '_sessions.remove(decodeId)?.dispose()',
)
require(
    'packages/sessions/test/live_coordinator_test.dart',
    'logical source watch rebinds after aliased physical owner retires',
)
require(
    'packages/sessions/test/download_session_test.dart',
    'Reader ingress registry replaces a retired same-id session generation',
)

for path in (
    'docs/archive/adr/0232-logical-source-watch-physical-generation-binding.md',
    'docs/archive/audits/dev253-logical-source-watch-generation-root-cause-audit.md',
    'docs/archive/audits/dev253-validation-results.md',
):
    if not (ROOT / path).is_file():
        raise SystemExit(f'missing dev.253 governance file: {path}')

require('docs/ARCHITECTURE.md', 'physical generation')
require('docs/SPEC.md', 'physical session/projection generation', 'same DownloadId对应新的DownloadSession对象')
require('tool/check.sh', 'test_dev253_logical_source_watch_generation_binding.py')

# Scope guard: source-generation closure must not mutate scheduler/window policy.
reject(
    'packages/sessions/lib/src/live_coordinator.dart',
    'sourceRebindTimeout',
    'waitingSourceTimeout',
)
print('dev.253 logical source-watch physical-generation binding: OK')

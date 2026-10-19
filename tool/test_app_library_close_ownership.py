#!/usr/bin/env python3
"""Keep App runtime library close ownership single and explicit."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = (ROOT / 'apps/app/lib/app_runtime.dart').read_text(encoding='utf-8')


def require(marker: str, label: str) -> None:
    if marker not in RUNTIME:
        raise SystemExit(f'app library close ownership missing {label}: {marker}')


for marker, label in (
    ('final bool ownsLibraryStore;', 'service ownership field'),
    ('this.ownsLibraryStore = false,', 'safe no-library default'),
    ('ownsLibraryStore = false;', 'shared bootstrap ownership release'),
    ('ownsLibraryStore: ownsLibraryStore,', 'open-services ownership publication'),
    ('ownsLibraryStore: previous.ownsLibraryStore,', 'download rebuild ownership handoff'),
    (
        'ownsLibraryStore: previous?.ownsLibraryStore ?? false,',
        'degraded service ownership handoff',
    ),
    ('if (ownsLibraryStore) {\n      try {\n        await libraryStore?.close();', 'owner-only service close'),
    ('unawaited(_bootstrapLibrary.close());', 'bootstrap owner teardown'),
):
    require(marker, label)

bootstrap_start = RUNTIME.index('if (bootstrap is LazyImportedLibraryStore) {')
bootstrap_end = RUNTIME.index('  } else {', bootstrap_start)
bootstrap_body = RUNTIME[bootstrap_start:bootstrap_end]
if not (
    bootstrap_body.index('libraryStore = await bootstrap.ensureDurable();')
    < bootstrap_body.index('ownsLibraryStore = false;')
):
    raise SystemExit('shared bootstrap durable store must release _AppServices close ownership')

close_start = RUNTIME.index('Future<void> _close({', RUNTIME.index('final class _AppServices'))
close_end = RUNTIME.index('\n}\n\nfinal class _AndroidArtifactPresentationFileLeaseFactory', close_start)
close_body = RUNTIME[close_start:close_end]
if close_body.count('await libraryStore?.close();') != 1:
    raise SystemExit('AppServices close must have exactly one owner-guarded library close')

print('App library close ownership: OK')

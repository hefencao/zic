#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
chapter = (ROOT / 'packages/downloads/lib/src/chapter_downloads.dart').read_text(encoding='utf-8')
persistent_store = (ROOT / 'packages/downloads/lib/src/persistent_download_artifact_store.dart').read_text(encoding='utf-8')
live = (ROOT / 'packages/sessions/lib/src/live_coordinator.dart').read_text(encoding='utf-8')

required = (
    'final Map<DownloadId, Future<void>> _artifactWrites =',
    '_transferDemandsForDownloads(_downloads)',
    'for (final entry in downloads.entries)',
    'priority: entry.value.priority',
    'reason: entry.value.reason',
    'flowTargetFrames: entry.value.flowTargetFrames',
)
for token in required:
    text = persistent_store if '_artifactWrites' in token else live
    if token not in text:
        raise SystemExit(f'dev.224 missing compile-closure token: {token}')

forbidden = (
    'for (final entry in update.plan.downloads.entries)',
    'final frameIndex = uploads?.takeDueFrame(id);\n    final frameIndex = uploads?.takeDueFrame(id);',
)
for token in forbidden:
    if token in live:
        raise SystemExit(f'dev.224 stale migration residue: {token}')

# Catch the most common text-migration failure: duplicated adjacent local
# declarations in the two production files changed by this closure.
for rel in (
    'packages/downloads/lib/src/chapter_downloads.dart',
    'packages/downloads/lib/src/persistent_download_artifact_store.dart',
    'packages/sessions/lib/src/live_coordinator.dart',
):
    lines = (ROOT / rel).read_text(encoding='utf-8').splitlines()
    for index, (left, right) in enumerate(zip(lines, lines[1:]), start=1):
        a = left.strip()
        b = right.strip()
        if a == b and re.match(r'^(?:final|late final|var|const)\b', a):
            raise SystemExit(
                f'dev.224 adjacent duplicate declaration at {rel}:{index}: {a}'
            )

print('dev.224 chapter migration compile closure: OK')

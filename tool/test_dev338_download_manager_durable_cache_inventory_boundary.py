#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SERVICE = ROOT / 'packages/downloads/lib/src/persistent_chapter_download_service.dart'
body = SERVICE.read_text(encoding='utf-8')
start = body.index('  ChapterCacheManagementProjection _buildCacheManagementProjection(')
end = body.index('  Future<List<ChapterDownloadSnapshot>> _inspectManyFromRecords(', start)
projection = body[start:end]

required = (
    'final exactIndexed = indexed[id.key];',
    'artifactStore._isVerifiedReadyRecord(exactIndexed)',
    'final physical = physicalState.pageState(',
    'physicalState.artifacts.containsKey(physicalId)',
    'physicalState.partials.containsKey(physicalId)',
)
for marker in required:
    if marker not in projection:
        raise SystemExit(
            'dev.338 durable cache inventory boundary missing: ' + marker
        )

for forbidden in (
    'transferRuntime.registry',
    'registry.find(',
    'registry.get(',
    'hasCanonicalHotSession',
    'session?.committedLength',
    'session?.state',
):
    if forbidden in projection:
        raise SystemExit(
            'dev.338 cache management leaked hot transfer-session state: ' + forbidden
        )

print('dev.338 Download Manager durable cache inventory boundary: OK')

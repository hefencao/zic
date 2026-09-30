#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'packages/downloads/lib/src/persistent_chapter_download_service.dart').read_text()

errors = []

def require(needle: str, message: str) -> None:
    if needle not in source:
        errors.append(message)

def forbid(needle: str, message: str) -> None:
    if needle in source:
        errors.append(message)

require('static const int _chapterNetworkWindow = 2;',
        'chapter network window must remain bounded at 2')
require("downloadBucketLimitFor: (_) => 2,",
        'chapter command NetLane bucket must remain aligned with the 2-page window')
require('final settled = await Future.any(pendingPages.values);',
        'chapter orchestration must slide on the next fully-settled page')
require('pendingDemands.remove(settled.id);',
        'settled page demand must leave the chapter claim set before refill')
require('if (settled.failure != null) {\n            await drainPendingPages(initialFailure: settled);',
        'first page failure must stop admission and drain already-admitted work')
require('Map<DownloadId, TransferDemand>.of(pendingDemands)',
        'chapter window must reuse the existing consumer demand authority')
forbid('Future.wait<void>(\n            List<Future<void>>.of(pendingPages)',
       'chapter command regressed to batch-wide barrier scheduling')

if errors:
    for error in errors:
        print(f'FAIL: {error}')
    raise SystemExit(1)
print('chapter download sliding-window ownership: OK')

#!/usr/bin/env python3
"""Ownership gate for dev.294 vertical jitter actual-layout observability."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'FAIL: {path} missing dev.294 tokens: {missing}')

def forbid(path: str, *tokens: str) -> None:
    text = read(path)
    found = [token for token in tokens if token in text]
    if found:
        raise SystemExit(f'FAIL: {path} contains forbidden dev.294 tokens: {found}')

require('apps/app/pubspec.yaml', 'version: 0.31.0+294')
require('apps/app/android/zic-version.properties', 'versionCode=294')
require('packages/telemetry/lib/src/trace.dart', 'pageLayoutSnapshot,')
require(
    'packages/reader/lib/src/reader_view.dart',
    "GlobalKey(debugLabel: 'reader-vertical-layout:$index')",
    'forceLayoutSnapshot: true',
    'now - _lastVerticalLayoutSnapshotMicros < 100000',
    'visible.take(8)',
    'TraceEventKind.pageLayoutSnapshot',
    "'expectedExtent': expectedExtent",
    "'renderHeight': renderObject.size.height",
    "'extentDeltaPx': renderObject.size.height - expectedExtent",
    "'layoutResidualPx':",
    'globalOrigin.dy + pixels - expected.start',
    "'globalTop': globalOrigin.dy",
    "'transformM00': transform[0]",
    "'transformTy': transform[13]",
)
require(
    'apps/app/lib/debug_trace.dart',
    'TraceEventKind.pageLayoutSnapshot',
    "'extentDeltaPx'",
    "'layoutResidualPx'",
    "'transformTx'",
    'TraceEventKind.pageLayoutSnapshot => _exportScrollWindowMicros',
)
require(
    'packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart',
    'forwardEncodedPages: 7',
    'backwardEncodedPages: 3',
    'forwardDecodePages: 2',
    'backwardDecodePages: 1',
)
require(
    'docs/adr/0273-vertical-jitter-actual-layout-observability.md',
    '缩放/比例异常已经在前一轮修复后解决',
    'observation-only',
    'external Texture/SurfaceProducer compositor',
)
require(
    'docs/NEXT_CHAT_HANDOFF.md',
    '# dev.294 后续交接',
    '缩放/比例异常解决',
    '`pageLayoutSnapshot`',
)
forbid(
    'packages/reader/lib/src/reader_view.dart',
    'presentationExtentAt(',
)
print('dev.294 vertical jitter actual-layout observability: OK')

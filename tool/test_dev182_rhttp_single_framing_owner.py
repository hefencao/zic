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
        raise SystemExit(f'forbidden {label}: {token}')

transport = read('packages/downloads_bridge/lib/src/rhttp_source_resource_transport.dart')
for token in (
    'for (final chunk in prefetched)',
    'while (!aborted && await iterator.moveNext())',
    'yield chunk;',
    'DownloadJob is the single',
):
    require(transport, token, 'rhttp raw streaming handoff')
forbid(transport, 'RhttpChunkCoalescer', 'transport-level duplicate framing')
for path in (
    'packages/downloads_bridge/lib/src/rhttp_chunk_coalescer.dart',
    'packages/downloads_bridge/test/rhttp_chunk_coalescer_test.dart',
):
    if (ROOT / path).exists():
        raise SystemExit(f'superseded transport framing file still exists: {path}')

job = read('packages/sessions/lib/src/download_job.dart')
for token in (
    'final pending = BytesBuilder(copy: false);',
    'var flushTarget = 16 * 1024;',
    'flushTarget = sourceProgressQuantumBytes;',
):
    require(job, token, 'DownloadJob sole framing owner')

job_test = read('packages/sessions/test/download_job_test.dart')
for token in (
    'coalesces tiny transport chunks before native/artifact ingress',
    'chunkSize: 1400',
    'appendCalls, lessThanOrEqualTo(6)',
):
    require(job_test, token, 'tiny-packet aggregation regression')

handoff = read('docs/NEXT_CHAT_HANDOFF.md')
require(handoff, 'rhttp transport不得再次增加64/256 KiB聚合', 'handoff framing ownership')

version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if version is None or int(version.group(1)) < 182 or android is None or android.group(1) != version.group(1):
    raise SystemExit('dev.182+ version mismatch')

print('dev.182 rhttp single framing owner: OK')

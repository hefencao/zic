#!/usr/bin/env python3
"""Guard dev.197 semantic trace export compaction and filtering boundaries."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
TRACE = (ROOT / 'apps/app/lib/debug_trace.dart').read_text(encoding='utf-8')
TEST = (ROOT / 'apps/app/test/misc_settings_test.dart').read_text(encoding='utf-8')
FILTER = (ROOT / 'tool/filter_debug_trace.py').read_text(encoding='utf-8')
SPEC = (ROOT / 'docs/SPEC.md').read_text(encoding='utf-8')
STATUS = (ROOT / 'docs/IMPLEMENTATION_STATUS.md').read_text(encoding='utf-8')
HANDOFF = (ROOT / 'docs/NEXT_CHAT_HANDOFF.md').read_text(encoding='utf-8')

for token in (
    'TraceEventKind.framePipelineTiming,',
    'TraceEventKind.decodeRefill,',
    "'sourceLength',",
    "'sourceRevision',",
    "'consumedSourceRevision',",
    "'${event.payload['traceReason']}|${event.payload['dominantStage']}|'",
    "'${event.payload['role']}|${event.payload['stage']}|'",
):
    if token not in TRACE:
        raise SystemExit(f'dev.197 trace compaction contract missing: {token}')

for token in (
    'frame pipeline timing export folds only matching semantic buckets',
    'decode refill export folds same role stage and source-wake bucket',
    "expect(folded.payload['minSourceLength'], 1000);",
    "expect(folded.payload['maxSourceRevision'], 3);",
):
    if token not in TEST:
        raise SystemExit(f'dev.197 trace regression missing: {token}')

for token in (
    "choices=('all', 'network', 'playback', 'failures')",
    "default='network'",
    'def filter_trace(',
    'with source.open(',
):
    if token not in FILTER:
        raise SystemExit(f'dev.197 streaming filter contract missing: {token}')

if 'downloadPriorityChanged' not in FILTER or 'sourceRead' not in FILTER:
    raise SystemExit('dev.197 network filter dropped authoritative network edges')
if 'framePipelineTiming' not in FILTER or 'decodeRefill' not in FILTER:
    raise SystemExit('dev.197 playback filter dropped pipeline diagnostics')

pubspec = (ROOT / 'apps/app/pubspec.yaml').read_text(encoding='utf-8')
properties = (ROOT / 'apps/app/android/zic-version.properties').read_text(encoding='utf-8')
app = re.search(r'^version: \d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)$', pubspec, re.MULTILINE)
android = re.search(r'^versionCode=(\d+)$', properties, re.MULTILINE)
if app is None or int(app.group(1)) < 197:
    raise SystemExit('dev.197-or-newer app build missing')
if android is None or int(android.group(1)) < 197:
    raise SystemExit('dev.197-or-newer Android version missing')

for body, name in ((STATUS, 'status'), (HANDOFF, 'handoff')):
    if 'dev.197' not in body:
        raise SystemExit(f'dev.197 missing from {name}')

for token in (
    'framePipelineTiming',
    'decodeRefill',
    '语义',
    '错误和生命周期边缘',
):
    if token not in SPEC:
        raise SystemExit(f'dev.197 stable trace export boundary missing from spec: {token}')

for path in (
    ROOT / 'docs/archive/adr/0178-semantic-debug-trace-export-compaction.md',
    ROOT / 'docs/archive/audits/dev197-trace-volume-root-cause-audit.md',
    ROOT / 'docs/archive/audits/dev197-validation-results.md',
):
    if not path.exists():
        raise SystemExit(f'dev.197 release document missing: {path.relative_to(ROOT)}')

print('dev.197 semantic trace export compaction: OK')

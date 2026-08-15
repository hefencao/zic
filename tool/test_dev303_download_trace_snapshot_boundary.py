#!/usr/bin/env python3
"""Ownership gate for dev.303 Download trace / snapshot publication separation."""
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]
def read(path): return (ROOT/path).read_text(encoding='utf-8')
def current_dev():
    for line in read('apps/app/pubspec.yaml').splitlines():
        if line.startswith('version:') and '+' in line:
            return int(line.rsplit('+',1)[1].strip())
    raise SystemExit('FAIL: app version code missing')
def require(path,*tokens):
    text=read(path); missing=[t for t in tokens if t not in text]
    if missing: raise SystemExit(f'FAIL: {path} missing dev.303 tokens: {missing}')
def forbid(path,*tokens):
    text=read(path); found=[t for t in tokens if t in text]
    if found: raise SystemExit(f'FAIL: {path} contains forbidden dev.303 tokens: {found}')
if current_dev() == 303:
    require('apps/app/pubspec.yaml','version: 0.31.0+303')
    require('apps/app/android/zic-version.properties','versionCode=303')
elif current_dev() < 303:
    raise SystemExit('FAIL: dev.303 gate executed before dev.303')
source=read('packages/sessions/lib/src/download_session.dart')
require('packages/sessions/lib/src/download_session.dart',
        'Diagnostics only. Snapshot publication is an independent lifecycle edge',
        'void _recordTrace(',
        'Priority belongs to transfer scheduling',
        'if (previous == null) {',
        'void _notifySnapshot()')
forbid('packages/sessions/lib/src/download_session.dart','void _emit(','_emit(')
match=re.search(r'void _recordTrace\([^}]+?\n  \}', source, flags=re.S)
if match is None:
    raise SystemExit('FAIL: cannot isolate _recordTrace body')
if '_notifySnapshot' in match.group(0):
    raise SystemExit('FAIL: _recordTrace must never publish DownloadSnapshot')
require('packages/sessions/test/download_session_test.dart',
        'priority-only demand migration does not rebroadcast media snapshot',
        'diagnostic transport trace does not publish media snapshot',
        'expect(snapshots, hasLength(1));',
        'expect(snapshots, hasLength(2));',
        'expect(snapshots, hasLength(3));')
require('packages/sessions/lib/src/download_session.dart',
        'void recordFlowControl({','void recordTransportReadPermit({','void recordResume({',
        'TraceEventKind.artifactSource')
require('packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart',
        'forwardEncodedPages: 7','backwardEncodedPages: 3',
        'forwardDecodePages: 2','backwardDecodePages: 1')
require('docs/adr/0282-download-trace-snapshot-publication-boundary.md',
        '状态：Accepted','10.213ms','_recordTrace()','0 个 snapshot','恰好 1 次')
require('docs/audits/dev303-download-trace-snapshot-publication-root-cause-audit.md',
        '重复 `_pump()`','无条件 `_notifySnapshot()`','Listener 所有权审计','1/10/1')
require('docs/ARCHITECTURE.md',
        'DownloadSession诊断Trace与DownloadSnapshot publication必须是两个独立ownership edge')
require('docs/SPEC.md',
        '`DownloadSession` diagnostics Trace emission与`DownloadSnapshot` publication MUST分离')
require('docs/NEXT_CHAT_HANDOFF.md','dev.303','10.213ms','dev.295目标已正面闭合')
print('dev.303 download trace / snapshot publication boundary: OK')

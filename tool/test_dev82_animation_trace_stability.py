#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

coordinator = read('packages/sessions/lib/src/live_coordinator.dart')
decode_registry = read('packages/sessions/lib/src/decode_registry.dart')
upload_registry = read('packages/sessions/lib/src/upload_registry.dart')
download = read('packages/sessions/lib/src/download_session.dart')
source_progress = read('packages/sessions/lib/src/source_progress.dart')
transport_test = read('packages/downloads/test/source_resource_transport_test.dart')
geometry_test = read('packages/reader/test/vertical_reader_geometry_test.dart')
webp = read('native/media_core/src/webp.rs')
trace = read('apps/app/lib/debug_trace.dart')

for token in (
    'snapshot.length - priorLength >= sourceProgressQuantumBytes',
    '_wakeDecode(sessionId, id, force: true)',
    '_decodeChangeNeedsUpload(before, after)',
    'snapshot.state == DecodeState.waitingSource',
):
    assert token in coordinator
assert 'void _wakeDecodes(' not in coordinator
assert 'Future<DecodeSnapshot> fill(' in decode_registry
assert 'Future<UploadSnapshot> prepare(' in upload_registry
assert 'sourceProgressQuantumBytes = 64 * 1024' in source_progress

for token in (
    '_pendingCommitTraceBytes >= sourceProgressQuantumBytes',
    "'chunks': _pendingCommitTraceChunks",
    '_flushCommittedTrace();',
):
    assert token in download

for token in (
    'map_rect_endpoints(',
    '.saturating_add(source.width)',
    'left.x + left.width, right.x',
    'bytes: self.canvas.clone(),',
):
    assert token in webp
assert 'scale_rect(' not in webp
assert 'endpoint_mapping_keeps_adjacent_strips_gapless' in webp

assert 'this.maxExportEvents = 10000' in trace
assert 'await body.close();' not in transport_test
assert 'await iterator.cancel();' in transport_test
assert 'await body.done;' in transport_test
assert 'closeTo(320, 1e-9)' in geometry_test
assert 'before?.epoch != after.epoch' in coordinator
assert 'before?.revision != after.revision' not in coordinator
assert '319.99999999999994' not in geometry_test

assert (ROOT / 'docs/adr/0066-frame-consumption-source-grid-composition-and-trace-aggregation.md').is_file()
assert (ROOT / 'docs/audits/dev82-vertical-animation-trace-stability-audit.md').is_file()
print('dev.82 animation geometry and trace stability: OK')

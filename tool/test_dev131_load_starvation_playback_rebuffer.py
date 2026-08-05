#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
coordinator = (ROOT / 'packages/sessions/lib/src/live_coordinator.dart').read_text()
upload = (ROOT / 'packages/sessions/lib/src/upload_session.dart').read_text()
pool = (ROOT / 'packages/bridge/lib/src/native_decode_pool.dart').read_text()
analyzer = (ROOT / 'tool/analyze_frame_pipeline_trace.py').read_text()

assert "'stage': 'decode-startup-deferred'" in coordinator
assert 'final deferredByStartup =' in coordinator
blocked = coordinator.index('final deferredByStartup =')
consumed = coordinator.index('_decodeSourceRevisions[id] = sourceRevision;', blocked)
segment = coordinator[blocked:consumed]
assert 'if (deferredByStartup)' in segment
assert '} else {' in segment
assert "_startupBufferSatisfied = false;\n      _startupBufferTarget = 0;" not in upload[
    upload.index('if (demand.role != PageRole.current)'):upload.index(
        'final prepared = _serializePrepare',
        upload.index('if (demand.role != PageRole.current)'),
    )
]
assert 'temporary\n      // transition/previous role must not arm the same gate again' in upload
assert 'if (worker.executionClass == DecodeExecutionClass.current)' in pool
assert 'playbackRebufferCount' in analyzer
assert 'decodeStartupDeferredCount' in analyzer
print('dev.131 load starvation/playback rebuffer gate: OK')

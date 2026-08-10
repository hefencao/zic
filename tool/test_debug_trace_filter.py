#!/usr/bin/env python3
"""Exercise focused streaming profiles for tool/filter_debug_trace.py."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / 'tool/filter_debug_trace.py'
spec = importlib.util.spec_from_file_location('filter_debug_trace', MODULE_PATH)
if spec is None or spec.loader is None:
    raise SystemExit('cannot load filter_debug_trace module')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

fixture = [
    {'t': 1, 'sessionId': 'reader', 'kind': 'downloadStarted', 'identityHash': 'a'},
    {'t': 2, 'sessionId': 'reader', 'kind': 'framePipelineTiming', 'identityHash': 'a'},
    {'t': 3, 'sessionId': 'reader', 'kind': 'resumeRestarted', 'identityHash': 'a'},
    {'t': 4, 'sessionId': 'reader', 'kind': 'downloadState', 'identityHash': 'b', 'payload': {'error': 'cancelled'}},
    {'t': 5, 'sessionId': 'other', 'kind': 'sourceRead', 'identityHash': 'c'},
]

with tempfile.TemporaryDirectory() as directory:
    directory = Path(directory)
    source = directory / 'trace.jsonl'
    source.write_text(
        ''.join(json.dumps(item, separators=(',', ':')) + '\n' for item in fixture),
        encoding='utf-8',
    )

    network = directory / 'network.jsonl'
    read_count, written_count = module.filter_trace(
        source,
        network,
        profile='network',
    )
    if (read_count, written_count) != (5, 4):
        raise SystemExit(f'unexpected network counts: {(read_count, written_count)}')
    network_kinds = [json.loads(line)['kind'] for line in network.read_text(encoding='utf-8').splitlines()]
    if network_kinds != ['downloadStarted', 'resumeRestarted', 'downloadState', 'sourceRead']:
        raise SystemExit(f'unexpected network profile: {network_kinds}')

    playback = directory / 'playback.jsonl'
    _, playback_count = module.filter_trace(source, playback, profile='playback')
    if playback_count != 2:
        raise SystemExit(f'unexpected playback count: {playback_count}')

    failures = directory / 'failures.jsonl'
    _, failures_count = module.filter_trace(source, failures, profile='failures')
    if failures_count != 2:
        raise SystemExit(f'unexpected failures count: {failures_count}')

    identity = directory / 'identity.jsonl'
    _, identity_count = module.filter_trace(
        source,
        identity,
        profile='network',
        identities=('a',),
        sessions=('reader',),
    )
    if identity_count != 2:
        raise SystemExit(f'unexpected identity/session count: {identity_count}')

print('debug trace streaming filter: OK')

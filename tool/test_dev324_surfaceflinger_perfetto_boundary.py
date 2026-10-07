#!/usr/bin/env python3
from pathlib import Path
import os
import runpy
import sqlite3
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def text(path):
    return (ROOT / path).read_text(encoding='utf-8')


def require(path, token, reason):
    body = text(path)
    if token not in body:
        raise SystemExit(f'{path}: missing {reason}: {token!r}')


config = 'tool/reader_surfaceflinger_perfetto.pbtxt'
capture = 'tool/capture_reader_surfaceflinger_perfetto.sh'
analyzer = 'tool/analyze_reader_surfaceflinger_perfetto.py'

for token in (
    'android.surfaceflinger.frametimeline',
    'android.surfaceflinger.layers',
    'TRACE_FLAG_COMPOSITION',
    'TRACE_FLAG_BUFFERS',
    'atrace_apps: "dev.zic.zic"',
):
    require(config, token, 'final-presentation Perfetto evidence source')

for token in (
    'SDK < 31',
    'ZIC_PERFETTO_DURATION_MS',
    'adb shell perfetto --txt -c -',
    'Reproduce the fixed-position Reader hitch now',
):
    require(capture, token, 'bounded device capture contract')

# Device commands are replaced with a local executable. Capture and pull failures
# must clean partial artifacts without replacing a previous valid output.
with tempfile.TemporaryDirectory(prefix='zic-perfetto-cleanup-') as directory:
    work = Path(directory)
    mock = work / 'adb'
    mock.write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
import sys

work = Path(os.environ['ZIC_MOCK_WORK'])
case = os.environ['ZIC_MOCK_CASE']
args = sys.argv[1:]
if args == ['shell', 'getprop', 'ro.build.version.sdk']:
    print('36')
elif args[:3] == ['shell', 'rm', '-f']:
    (work / 'remote').unlink(missing_ok=True)
elif args[:2] == ['shell', 'perfetto']:
    config = sys.stdin.read()
    assert 'duration_ms: 5000' in config
    (work / 'remote').write_bytes(b'captured-trace')
    if case == 'capture-failure':
        sys.exit(7)
elif args[:1] == ['pull']:
    output = Path(args[-1])
    if case == 'pull-failure':
        output.write_bytes(b'incomplete')
        sys.exit(8)
    output.write_bytes((work / 'remote').read_bytes())
else:
    raise AssertionError(args)
''')
    mock.chmod(0o755)
    output = work / 'current.perfetto-trace'
    for case in ('capture-failure', 'pull-failure', 'success'):
        output.write_bytes(b'previous-valid-trace')
        environment = dict(os.environ, ZIC_MOCK_WORK=str(work),
                           ZIC_MOCK_CASE=case, ZIC_PERFETTO_DURATION_MS='5000',
                           PATH=str(work) + os.pathsep + os.environ['PATH'])
        result = subprocess.run(['bash', str(ROOT / capture), str(output)],
                                env=environment, capture_output=True, text=True)
        assert result.returncode == {'capture-failure': 7,
                                     'pull-failure': 8, 'success': 0}[case], result
        expected = b'captured-trace' if case == 'success' else b'previous-valid-trace'
        assert output.read_bytes() == expected, case
        assert not (work / 'remote').exists(), case
        assert set(work.iterdir()) == {mock, output}, (case, list(work.iterdir()))

for token in (
    'actual_frame_timeline_slice',
    "p.name = 'dev.zic.zic'",
    "p.name = '/system/bin/surfaceflinger'",
    'present_gap_ns',
    'jank_type',
    'present_type',
    'latched_fence_state',
    'actual-presentation-jank-observed',
):
    require(analyzer, token, 'FrameTimeline analysis boundary')

require('CHANGELOG.md', '0.31.0-dev.324', 'changelog version')

# Perfetto display frames may have NULL, rather than zero, surface tokens.
# Run the actual SQL against both representations so SF samples cannot silently
# disappear while app rows still look valid.
module = runpy.run_path(str(ROOT / analyzer))
query = module['QUERY']
with sqlite3.connect(':memory:') as database:
    database.executescript('''
        CREATE TABLE process (upid INTEGER PRIMARY KEY, name TEXT);
        CREATE TABLE stats (name TEXT, severity TEXT, source TEXT,
                            idx INTEGER, value INTEGER);
        CREATE TABLE actual_frame_timeline_slice (
            upid INTEGER, surface_frame_token INTEGER, layer_name TEXT,
            ts INTEGER, dur INTEGER, jank_type TEXT, present_type TEXT,
            on_time_finish INTEGER, gpu_composition INTEGER,
            jank_severity_type TEXT, latched_fence_state TEXT
        );
        INSERT INTO process VALUES (1, 'dev.zic.zic');
        INSERT INTO process VALUES (2, '/system/bin/surfaceflinger');
        INSERT INTO actual_frame_timeline_slice VALUES
            (1, 9, 'app', 0, 8000000, 'None', 'On-time Present', 1, 0, NULL, NULL),
            (2, NULL, NULL, 0, 8000000, 'None', 'On-time Present', 1, 0, NULL, NULL),
            (2, 0, NULL, 8000000, 8000000, 'Display HAL', 'Late Present', 0, 0, NULL, NULL);
    ''')
    results = [database.execute(statement).fetchall()
               for statement in query.split(';') if statement.strip()]
    assert results[0][0][0] == 1, results[0]
    assert results[3][0] == (2, 1, 1), results[3]
    assert results[4] == [], results[4]
    columns = [entry[0] for entry in database.execute(query.split(';')[0]).description]
    app = dict(zip(columns, results[0][0]))
    verdict = module['evidence_verdict']
    assert verdict(app, [], [], []) == 'no-app-content-layer-frametimeline-evidence'
    assert verdict(app, [], [{'jank_type': 'Unknown Jank'}], []) == \
        'no-app-content-layer-frametimeline-evidence'
    database.execute("UPDATE actual_frame_timeline_slice SET layer_name = 'SurfaceView[dev.zic.zic]' WHERE upid = 1")
    app = dict(zip(columns, database.execute(query.split(';')[0]).fetchone()))
    assert app['app_content_frames'] == 1, app
    assert verdict(app, [], [], []) == 'no-final-presentation-jank-in-captured-window'
    # Service-global counters can predate this tracing session. BufferStats
    # counters identify discarded chunks from the captured buffers themselves.
    database.execute("INSERT INTO stats VALUES ('traced_chunks_discarded', 'info', 'trace', NULL, 4)")
    statements = [s for s in query.split(';') if s.strip()]
    assert database.execute(statements[4]).fetchall() == []
    database.executescript('''
        INSERT INTO stats VALUES
            ('interned_data_tokenizer_errors', 'error', 'trace', NULL, 3),
            ('traced_buf_chunks_discarded', 'info', 'trace', 0, 4),
            ('unrelated_stat', 'info', 'trace', NULL, 7),
            ('frame_timeline_event_parser_errors', 'error', 'trace', NULL, 0);
    ''')
    issues = database.execute(statements[4]).fetchall()
    assert len(issues) == 2, issues
    assert {row[0] for row in issues} == {
        'interned_data_tokenizer_errors', 'traced_buf_chunks_discarded',
    }, issues
    assert verdict(app, [], [], issues) == 'invalid-evidence-trace-loss-or-parser-errors'

print('dev.324 SurfaceFlinger Perfetto evidence boundary: OK')

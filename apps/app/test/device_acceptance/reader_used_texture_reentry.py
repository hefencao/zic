#!/usr/bin/env python3
"""Run isolated native Reader reentry; always restore the supplied ordinary APK."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import time

PACKAGE = 'dev.zic.zic'
REMOTE = 'files/zic-reader-used-texture-results.json'
INPUTS = 'files/zic-reader-used-texture-inputs'
SOURCE = Path(__file__).with_suffix('.dart')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--serial', required=True)
    p.add_argument('--fixture-apk', required=True, type=Path)
    p.add_argument('--restore-apk', required=True, type=Path)
    p.add_argument('--out', required=True, type=Path)
    p.add_argument('--sdk-root', type=Path, default=Path(os.environ.get(
        'ANDROID_SDK_ROOT', str(Path.home() / 'android-sdk'))))
    args = p.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    sha = lambda path: hashlib.sha256(Path(path).read_bytes()).hexdigest()
    record = {'fixture_source_sha256': sha(SOURCE), 'commands': [],
        'fixture_apk': {'path': str(args.fixture_apk), 'sha256': sha(args.fixture_apk)},
        'restore_apk': {'path': str(args.restore_apk), 'sha256': sha(args.restore_apk)}}

    def save():
        (args.out / 'result.json').write_text(json.dumps(record, indent=2) + '\n')

    def run(command, required=True):
        command = list(map(str, command))
        start = time.time_ns()
        r = subprocess.run(command, text=True, capture_output=True, timeout=180)
        record['commands'].append({'command': command, 'begin_ns': start,
            'end_ns': time.time_ns(), 'exit_code': r.returncode,
            'stdout': r.stdout, 'stderr': r.stderr})
        save()
        if required and r.returncode:
            raise RuntimeError(r.stdout + r.stderr)
        return r

    def adb(*command, required=True):
        return run(['adb', '-s', args.serial, *command], required)

    def certificate(apk):
        r = run([args.sdk_root / 'build-tools/36.0.0/apksigner',
            'verify', '--print-certs', apk])
        found = re.findall(r'^Signer #\d+ certificate SHA-256 digest: (\w+)$', r.stdout, re.M)
        if len(found) != 1:
            raise RuntimeError('Expected one signing certificate')
        return found[0]

    def install(apk, expected):
        if 'Success' not in adb('install', '-r', '-t', apk).stdout:
            raise RuntimeError('APK install did not succeed')
        paths = adb('shell', 'pm', 'path', PACKAGE).stdout.splitlines()
        base = next(x.removeprefix('package:') for x in paths if x.endswith('/base.apk'))
        if adb('shell', 'sha256sum', base).stdout.split()[0] != expected:
            raise RuntimeError('Installed APK differs from supplied artifact')

    if certificate(args.fixture_apk) != certificate(args.restore_apk):
        raise RuntimeError('Fixture/ordinary APK signing certificates differ')
    changed = False
    try:
        adb('shell', 'am', 'force-stop', PACKAGE)
        changed = True
        install(args.fixture_apk, record['fixture_apk']['sha256'])
        previous = adb('shell', 'run-as', PACKAGE, 'cat', REMOTE, required=False)
        if previous.returncode == 0:
            (args.out / 'previous-device-results.json').write_text(previous.stdout)
        adb('shell', 'run-as', PACKAGE, 'rm', '-f', REMOTE,
            REMOTE + '.trace.jsonl', REMOTE + '.wire.json')
        adb('shell', 'run-as', PACKAGE, 'mkdir', '-p', INPUTS)
        source = SOURCE.parent / 'fixtures/source_native_webp'
        manifest = json.loads((source / 'manifest.json').read_text())
        record['staged_inputs'] = []
        for item in manifest['fixtures']:
            raw = (source / (item['kind'] + '.webp')).read_bytes()
            if hashlib.sha256(raw).hexdigest() != item['sha256']:
                raise RuntimeError('Input hash differs from sealed WebP manifest')
            remote = INPUTS + '/' + item['kind'] + '.webp'
            shell = 'run-as ' + shlex.quote(PACKAGE) + ' sh -c ' + shlex.quote(
                'cat > ' + shlex.quote(remote))
            r = subprocess.run(['adb', '-s', args.serial, 'shell', '-T', shell],
                input=raw, capture_output=True, timeout=30)
            actual = adb('shell', 'run-as', PACKAGE, 'sha256sum', remote).stdout.split()[0]
            if r.returncode or r.stdout or actual != item['sha256']:
                raise RuntimeError('Private staged fixture input differs')
            record['staged_inputs'].append(dict(item, staged_sha256=actual))
        save()
        adb('shell', 'am', 'start', '-W', '-n', PACKAGE + '/.MainActivity')
        record['fixture_pid'] = adb('shell', 'pidof', PACKAGE).stdout.strip()
        start = time.monotonic()
        last_count = -1
        while time.monotonic() - start < 180:
            r = adb('shell', 'run-as', PACKAGE, 'cat', REMOTE, required=False)
            try:
                rows = json.loads(r.stdout) if r.returncode == 0 else []
            except json.JSONDecodeError:
                rows = []
            if rows:
                record['case_results'] = rows
                save()
                if len(rows) != last_count:
                    last_count = len(rows)
                    print('Device cases:', len(rows), rows[-1]['case'], rows[-1]['status'], flush=True)
                if rows[-1]['case'] == 'complete':
                    if rows[-1]['status'] != 'passed' or len(rows) != 7:
                        raise RuntimeError('Dart native texture fixture failed: ' + str(rows[-1]))
                    expected = {f'{kind}-entry-{entry}' for kind in ('static', 'animated')
                        for entry in range(3)}
                    if {r['case'] for r in rows[:-1]} != expected:
                        raise RuntimeError('Missing native texture case')
                    record['device_cases_passed'] = True
                    break
            time.sleep(.5)
        else:
            raise RuntimeError('Native fixture did not reach a terminal result')
    finally:
        for suffix in ['', '.trace.jsonl', '.wire.json']:
            r = adb('shell', 'run-as', PACKAGE, 'cat', REMOTE + suffix, required=False)
            target = args.out / ('device-results.json' if not suffix else suffix[1:])
            target.write_text(r.stdout)
        if changed:
            adb('shell', 'am', 'force-stop', PACKAGE)
            adb('shell', 'run-as', PACKAGE, 'rm', '-rf', INPUTS, REMOTE,
                REMOTE + '.trace.jsonl', REMOTE + '.wire.json')
            install(args.restore_apk, record['restore_apk']['sha256'])
            adb('shell', 'am', 'start', '-W', '-n', PACKAGE + '/.MainActivity')
            record['ordinary_APK_restored'] = True
            record['ordinary_pid'] = adb('shell', 'pidof', PACKAGE).stdout.strip()
        save()
    print('Six native texture reentry cases passed; ordinary APK restored.', flush=True)


if __name__ == '__main__':
    main()

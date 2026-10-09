#!/usr/bin/env python3
"""Observe original native decode retirement in a separate Android package."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import time

PACKAGE = 'dev.zic.activenativeretirement'
USER_PACKAGE = 'dev.zic.zic'
REMOTE = 'files/native-retirement-results.json'
SOURCE = Path(__file__).with_suffix('.dart')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--serial', required=True)
    p.add_argument('--fixture-apk', required=True, type=Path)
    p.add_argument('--ordinary-apk', required=True, type=Path)
    p.add_argument('--input', required=True, type=Path)
    p.add_argument('--input-sha256', required=True)
    p.add_argument('--handoff-only', action='store_true')
    p.add_argument('--out', required=True, type=Path)
    p.add_argument('--sdk-root', type=Path, default=Path(os.environ.get(
        'ANDROID_SDK_ROOT', str(Path.home() / 'android-sdk'))))
    args = p.parse_args()
    if not re.fullmatch('[a-f0-9]{64}', args.input_sha256):
        p.error('--input-sha256 must be a sealed SHA-256 digest')
    args.out.mkdir(parents=True, exist_ok=True)
    sha = lambda path: hashlib.sha256(Path(path).read_bytes()).hexdigest()
    record = {'fixture_source_sha256': sha(SOURCE), 'commands': [],
        'fixture_package': PACKAGE,
        'fixture_apk': {'path': str(args.fixture_apk), 'sha256': sha(args.fixture_apk)},
        'ordinary_apk': {'path': str(args.ordinary_apk), 'sha256': sha(args.ordinary_apk)},
        'input': {'path': str(args.input), 'sha256': args.input_sha256,
            'bytes': args.input.stat().st_size}}
    if sha(args.input) != args.input_sha256:
        raise RuntimeError('Input differs from supplied sealed digest')

    def save():
        (args.out / 'result.json').write_text(json.dumps(record, indent=2) + '\n')

    def run(command, required=True):
        command = list(map(str, command))
        start = time.time_ns()
        r = subprocess.run(command, text=True, capture_output=True, timeout=180)
        record['commands'].append({'command': command, 'begin_ns': start,
            'end_ns': time.time_ns(), 'exit_code': r.returncode,
            'stdout': r.stdout[-4096:], 'stderr': r.stderr[-4096:],
            'stdout_chars': len(r.stdout), 'stderr_chars': len(r.stderr)})
        save()
        if required and r.returncode:
            raise RuntimeError('Command failed: ' + str(command[:5]))
        return r

    def adb(*command, required=True):
        return run(['adb', '-s', args.serial, *command], required)

    def installed_hash(package):
        paths = adb('shell', 'pm', 'path', package).stdout.splitlines()
        base = next(x.removeprefix('package:') for x in paths if x.endswith('/base.apk'))
        return adb('shell', 'sha256sum', base).stdout.split()[0]

    expected = record['ordinary_apk']['sha256']
    if installed_hash(USER_PACKAGE) != expected:
        raise RuntimeError('Installed ordinary APK differs; user package was not changed')
    badging = run([args.sdk_root / 'build-tools/36.0.0/aapt2',
        'dump', 'badging', args.fixture_apk]).stdout
    if "package: name='" + PACKAGE + "'" not in badging:
        raise RuntimeError('Fixture must use the separate test applicationId')
    if adb('shell', 'pm', 'path', PACKAGE, required=False).stdout.strip():
        raise RuntimeError('Previous test package exists; preserve its evidence before removing it')
    installed = False
    try:
        installed = True
        if 'Success' not in adb('install', '-r', '-t', args.fixture_apk).stdout:
            raise RuntimeError('Fixture installation failed')
        if installed_hash(PACKAGE) != record['fixture_apk']['sha256']:
            raise RuntimeError('Installed fixture differs from supplied APK')
        adb('shell', 'run-as', PACKAGE, 'mkdir', '-p', 'files/inputs')
        remote = 'files/inputs/decode-4096.webp'
        shell = 'run-as ' + shlex.quote(PACKAGE) + ' sh -c ' + shlex.quote(
            'cat > ' + shlex.quote(remote))
        r = subprocess.run(['adb', '-s', args.serial, 'shell', '-T', shell],
            input=args.input.read_bytes(), capture_output=True, timeout=45)
        actual = adb('shell', 'run-as', PACKAGE, 'sha256sum', remote).stdout.split()[0]
        if r.returncode or r.stdout or actual != args.input_sha256:
            raise RuntimeError('Private staged input differs')
        record['staged_input_sha256'] = actual
        if args.handoff_only:
            current = SOURCE.parent / 'fixtures/source_native_webp/static.webp'
            shell = 'run-as ' + shlex.quote(PACKAGE) + ' sh -c ' + shlex.quote(
                'cat > files/inputs/static.webp')
            r = subprocess.run(['adb', '-s', args.serial, 'shell', '-T', shell],
                input=current.read_bytes(), capture_output=True, timeout=45)
            actual = adb('shell', 'run-as', PACKAGE, 'sha256sum',
                'files/inputs/static.webp').stdout.split()[0]
            if r.returncode or r.stdout or actual != sha(current):
                raise RuntimeError('Current handoff input differs')
        adb('shell', 'am', 'start', '-W', '-n', PACKAGE + '/dev.zic.zic.MainActivity')
        record['fixture_pid'] = adb('shell', 'pidof', PACKAGE).stdout.strip()
        start = time.monotonic()
        last_count = -1
        while time.monotonic() - start < 120:
            r = adb('exec-out', 'run-as', PACKAGE, 'cat', REMOTE, required=False)
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
                    expected_cases = {'current-handoff', 'complete'} if args.handoff_only else {
                        'drain', 'rapid-reentry', 'complete'}
                    if len(rows) != len(expected_cases) or {x['case'] for x in rows} != expected_cases or any(
                            x['status'] != 'passed' for x in rows):
                        raise RuntimeError('Native decode acceptance failed; inspect device-results.json')
                    record['device_cases_passed'] = True
                    break
            time.sleep(.5)
        else:
            raise RuntimeError('Native fixture did not reach a terminal result')
    finally:
        try:
            for suffix in ['', '.trace.jsonl', '.observers.json']:
                r = adb('exec-out', 'run-as', PACKAGE, 'cat', REMOTE + suffix, required=False)
                target = args.out / ('device-results.json' if not suffix else suffix[1:])
                target.write_text(r.stdout)
            if not record.get('device_cases_passed', False):
                (args.out / 'device.log').write_text(adb('logcat', '-d', '-t', '2000',
                    required=False).stdout)
        finally:
            if installed:
                adb('shell', 'am', 'force-stop', PACKAGE, required=False)
                record['test_package_removed'] = 'Success' in adb('uninstall', PACKAGE,
                    required=False).stdout
            record['test_package_absent'] = not adb('shell', 'pm', 'path', PACKAGE,
                required=False).stdout.strip()
            record['user_apk_unchanged'] = installed_hash(USER_PACKAGE) == expected
            adb('shell', 'am', 'start', '-W', '-n', USER_PACKAGE + '/.MainActivity')
            record['ordinary_pid'] = adb('shell', 'pidof', USER_PACKAGE).stdout.strip()
            save()
    if not record['test_package_absent'] or not record['user_apk_unchanged']:
        raise RuntimeError('Package cleanup or ordinary APK verification failed')
    print('Requested native cases passed; test package removed; ordinary APK unchanged.',
        flush=True)


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Run the test-only source-runtime resolver network Pipeline entry and always restore an ordinary APK."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

PACKAGE = 'dev.zic.zic'
REMOTE = 'files/zic-source-runtime-network-pipeline-results.json'
SOURCE = Path(__file__).with_suffix('.dart')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--fixture-apk', type=Path, required=True)
    parser.add_argument('--restore-apk', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--sdk-root', type=Path, default=Path(
        os.environ.get('ANDROID_SDK_ROOT', str(Path.home() / 'android-sdk'))))
    parser.add_argument('--timeout', type=int, default=180)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    record = {'fixture_source_sha256': hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
        'commands': [], 'production_apk_modified': False, 'case_results': []}

    def save():
        (args.out / 'result.json').write_text(json.dumps(record, indent=2) + '\n')

    def run(command, *, required=True, timeout=180):
        command = list(map(str, command))
        begin = time.time_ns()
        result = subprocess.run(command, text=True, capture_output=True, timeout=timeout)
        record['commands'].append({'command': command, 'begin_ns': begin,
            'end_ns': time.time_ns(), 'exit_code': result.returncode,
            'stdout': result.stdout, 'stderr': result.stderr})
        save()
        if required and result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        return result

    def adb(*command, required=True, timeout=180):
        return run(['adb', '-s', args.serial, *command], required=required, timeout=timeout)

    def cert(apk):
        signer = args.sdk_root / 'build-tools/36.0.0/apksigner'
        result = run([signer, 'verify', '--print-certs', apk])
        matches = re.findall(r'^Signer #\d+ certificate SHA-256 digest: (\w+)$',
            result.stdout, re.M)
        if len(matches) != 1:
            raise RuntimeError('Expected one verified signing certificate')
        return matches[0]

    for name in ('fixture_apk', 'restore_apk'):
        apk = getattr(args, name).resolve()
        record[name] = {'path': str(apk), 'sha256': hashlib.sha256(apk.read_bytes()).hexdigest()}
    if cert(args.fixture_apk) != cert(args.restore_apk):
        raise RuntimeError('Fixture and ordinary restore APK signing certificates differ')

    def install(apk, expected):
        result = adb('install', '-r', '-t', apk)
        if 'Success' not in result.stdout:
            raise RuntimeError(result.stdout + result.stderr)
        paths = adb('shell', 'pm', 'path', PACKAGE).stdout.splitlines()
        base = [p.removeprefix('package:') for p in paths if p.endswith('/base.apk')]
        if len(base) != 1 or adb('shell', 'sha256sum', base[0]).stdout.split()[0] != expected:
            raise RuntimeError('Installed APK does not match supplied artifact')

    changed = False
    try:
        previous = adb('shell', 'run-as', PACKAGE, 'cat', REMOTE, required=False)
        if previous.returncode == 0:
            (args.out / 'previous-device-results.json').write_text(previous.stdout)
        adb('shell', 'am', 'force-stop', PACKAGE)
        changed = True
        install(args.fixture_apk, record['fixture_apk']['sha256'])
        adb('shell', 'run-as', PACKAGE, 'rm', '-f', REMOTE)
        adb('shell', 'am', 'start', '-W', '-n', PACKAGE + '/.MainActivity')
        record['fixture_app_pid'] = adb('shell', 'pidof', PACKAGE).stdout.strip()
        started = time.monotonic()
        last_count = -1
        screenshots = set()
        while time.monotonic() - started < args.timeout:
            result = adb('shell', 'run-as', PACKAGE, 'cat', REMOTE,
                required=False, timeout=15)
            if result.returncode == 0:
                try:
                    rows = json.loads(result.stdout)
                except json.JSONDecodeError:
                    rows = []
                if rows:
                    record['case_results'] = rows
                    if len(rows) != last_count:
                        last_count = len(rows)
                        print('Device cases:', len(rows), rows[-1]['case'],
                            rows[-1]['status'], flush=True)
                    save()
                    latest = rows[-1]
                    if latest.get('reader_mounted') and latest['case'] not in screenshots:
                        screenshots.add(latest['case'])
                        target = args.out / (latest['case'] + '.png')
                        image = subprocess.run(['adb', '-s', args.serial, 'exec-out',
                            'screencap', '-p'], capture_output=True, check=True, timeout=15)
                        target.write_bytes(image.stdout)
                        record.setdefault('screenshots', []).append({'case': latest['case'],
                            'path': str(target), 'sha256': hashlib.sha256(image.stdout).hexdigest(),
                            'captured_at_ns': time.time_ns()})
                        save()
                    if rows[-1]['case'] == 'complete':
                        if rows[-1]['status'] != 'passed':
                            raise RuntimeError('Dart body fixture failed: ' + str(rows[-1]))
                        if len(rows) != 5 or rows[-1]['cases'] != 4:
                            raise RuntimeError('Incomplete Dart Pipeline case count')
                        expected = {'resolver-transient', 'resolver-exhausted',
                            'cancel-resolver-active', 'cancel-resolver-backoff'}
                        if {row['case'] for row in rows[:-1]} != expected:
                            raise RuntimeError('Missing or duplicated failure/retry case')
                        record['device_cases_passed'] = True
                        break
            time.sleep(.5)
        else:
            raise RuntimeError('Dart fixture timed out without a terminal result')
        (args.out / 'device-results.json').write_text(json.dumps(
            record['case_results'], ensure_ascii=False, indent=2) + '\n')
    finally:
        trace = adb('shell', 'run-as', PACKAGE, 'cat', REMOTE + '.trace.jsonl',
            required=False).stdout
        (args.out / 'trace.jsonl').write_text(trace)
        record['trace_sha256'] = hashlib.sha256(trace.encode()).hexdigest()
        log = adb('logcat', '-d', '-v', 'threadtime', required=False).stdout
        (args.out / 'logcat.txt').write_text(log)
        if changed:
            adb('shell', 'am', 'force-stop', PACKAGE)
            install(args.restore_apk, record['restore_apk']['sha256'])
            adb('shell', 'am', 'start', '-W', '-n', PACKAGE + '/.MainActivity')
            record['ordinary_APK_restored'] = True
            record['ordinary_app_pid'] = adb('shell', 'pidof', PACKAGE).stdout.strip()
        save()
    print('Four actual source-runtime resolver network Pipeline cases passed; ordinary APK restored.', flush=True)


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Run the test-only source Pipeline/persistent cache entry and always restore an ordinary APK."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import time
import xml.etree.ElementTree as ET

PACKAGE = 'dev.zic.zic'
REMOTE = 'files/zic-source-native-webp-pipeline-results.json'
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
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--transition-only', action='store_true',
        help='Run the build with ZIC_SOURCE_NATIVE_WEBP_TRANSITION_ONLY=true')
    mode.add_argument('--partial-only', action='store_true',
        help='Run the build with ZIC_SOURCE_NATIVE_WEBP_PARTIAL_ONLY=true')
    mode.add_argument('--partial-failures-only', action='store_true',
        help='Run the build with ZIC_SOURCE_NATIVE_WEBP_PARTIAL_FAILURES_ONLY=true')
    mode.add_argument('--partial-metadata-only', action='store_true',
        help='Run the build with ZIC_SOURCE_NATIVE_WEBP_PARTIAL_METADATA_ONLY=true')
    mode.add_argument('--cross-provider-partial-only', action='store_true',
        help='Run the build with ZIC_SOURCE_NATIVE_WEBP_CROSS_PROVIDER_PARTIAL_ONLY=true')
    mode.add_argument('--capacity-only', action='store_true',
        help='Run the build with ZIC_SOURCE_NATIVE_WEBP_CAPACITY_ONLY=true')
    mode.add_argument('--alias-only', action='store_true',
        help='Run the build with ZIC_SOURCE_NATIVE_WEBP_ALIAS_ONLY=true')
    mode.add_argument('--pressure-only', action='store_true',
        help='Run the build with ZIC_SOURCE_NATIVE_WEBP_PRESSURE_ONLY=true')
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
            'stdout': result.stdout[-4096:], 'stderr': result.stderr[-4096:],
            'stdout_chars': len(result.stdout), 'stderr_chars': len(result.stderr)})
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

    def drag(start_fraction, end_fraction, duration):
        # Resolve the actual Reader surface afresh; never reuse device coordinates.
        remote = '/sdcard/zic-source-native-webp-gesture.xml'
        try:
            adb('shell', 'uiautomator', 'dump', remote)
            xml = adb('shell', 'cat', remote).stdout
            nodes = [node for node in ET.fromstring(xml).iter('node')
                if node.get('content-desc') == '正文拖动验收区域']
            if len(nodes) != 1 or nodes[0].get('enabled') == 'false':
                raise RuntimeError('Expected one enabled current Reader gesture surface')
            match = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',
                nodes[0].get('bounds', ''))
            if not match:
                raise RuntimeError('Reader gesture surface has no actual bounds')
            left, top, right, bottom = map(int, match.groups())
            if right - left < 100 or bottom - top < 100:
                raise RuntimeError('Reader gesture surface is clipped or absent')
            y = (top + bottom) // 2
            adb('shell', 'input', 'swipe',
                left + int((right - left) * start_fraction), y,
                left + int((right - left) * end_fraction), y, duration)
        finally:
            adb('shell', 'rm', '-f', remote, required=False)

    changed = False
    try:
        adb('shell', 'am', 'force-stop', PACKAGE)
        changed = True
        install(args.fixture_apk, record['fixture_apk']['sha256'])
        adb('shell', 'run-as', PACKAGE, 'rm', '-f', REMOTE)
        inputs = SOURCE.parent / 'fixtures/source_native_webp'
        manifest = json.loads((inputs / 'manifest.json').read_text())
        record['input_manifest_sha256'] = hashlib.sha256((inputs / 'manifest.json').read_bytes()).hexdigest()
        adb('shell', 'run-as', PACKAGE, 'mkdir', '-p', 'files/zic-source-native-webp-inputs')
        record['staged_inputs'] = []
        for item in manifest['fixtures']:
            raw = (inputs / (item['kind'] + '.webp')).read_bytes()
            if hashlib.sha256(raw).hexdigest() != item['sha256']:
                raise RuntimeError('Fixture WebP does not match sealed input manifest')
            remote = 'files/zic-source-native-webp-inputs/' + item['kind'] + '.webp'
            script = 'cat > ' + shlex.quote(remote)
            command = ['adb', '-s', args.serial, 'shell', '-T',
                'run-as ' + shlex.quote(PACKAGE) + ' sh -c ' + shlex.quote(script)]
            begin = time.time_ns()
            stage = subprocess.run(command, input=raw, capture_output=True, timeout=30)
            record.setdefault('input_staging_commands', []).append({
                'command': command, 'begin_ns': begin, 'end_ns': time.time_ns(),
                'exit_code': stage.returncode, 'stdout_bytes': len(stage.stdout),
                'stderr': stage.stderr.decode()})
            save()
            if stage.returncode or stage.stdout:
                raise RuntimeError('Private fixture input staging failed: ' + stage.stderr.decode())
            actual = adb('shell', 'run-as', PACKAGE, 'sha256sum', remote).stdout.split()[0]
            if actual != item['sha256']:
                raise RuntimeError('Staged fixture WebP differs from source asset')
            record['staged_inputs'].append(dict(item, actual_staged_sha256=actual))
        save()
        adb('shell', 'am', 'start', '-W', '-n', PACKAGE + '/.MainActivity')
        record['fixture_app_pid'] = adb('shell', 'pidof', PACKAGE).stdout.strip()
        started = time.monotonic()
        last_count = -1
        screenshots = set()
        gestures = set()
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
                    if args.transition_only and latest['case'] not in gestures:
                        if latest['case'] == 'transition-awaiting-drag':
                            gestures.add(latest['case'])
                            drag(.8, .55, 1400)
                        elif latest['case'] == 'transition-awaiting-reverse':
                            gestures.add(latest['case'])
                            drag(.8, .2, 700)
                            time.sleep(.7)
                            drag(.2, .8, 700)
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
                        expected_count = (1 if args.transition_only or args.partial_metadata_only or args.capacity_only else 2 if args.partial_only or args.alias_only or args.pressure_only
                            else 3 if args.cross_provider_partial_only
                            else 4 if args.partial_failures_only else 6)
                        expected_rows = 4 if args.transition_only else expected_count + 1
                        if len(rows) != expected_rows or rows[-1]['cases'] != expected_count:
                            raise RuntimeError('Incomplete Dart Pipeline case count')
                        expected = ({'transition-awaiting-drag', 'transition-awaiting-reverse',
                            'transition-zero-current'} if args.transition_only else
                            {'partial-first-presentation', 'partial-cold-reentry'} if args.partial_only else
                            {'partial-network-metadata'} if args.partial_metadata_only else
                            {'cross-provider-partial-first', 'cross-provider-partial-b',
                                'cross-provider-partial-a'} if args.cross_provider_partial_only else
                            {'capacity'} if args.capacity_only else
                            {'alias-required-exact', 'alias-late-proof'} if args.alias_only else
                            {'body-read-preemption', 'retention-exit-reacquire'} if args.pressure_only else
                            {'partial-range-EOF', 'partial-range-mismatch', 'partial-full-body-EOF',
                                'partial-network-metadata'} if args.partial_failures_only else
                            {f'{plane}-{case}' for plane in ('static', 'animated')
                                for case in ('first-download', 'cold-READY', 'route-cancellation')})
                        if {row['case'] for row in rows[:-1]} != expected:
                            raise RuntimeError('Missing or duplicated Pipeline case')
                        expected_requests = (13 if args.pressure_only else 7 if args.capacity_only else
                            3 if args.alias_only or args.cross_provider_partial_only else
                            2 if args.transition_only or args.partial_only or args.partial_metadata_only else
                            5 if args.partial_failures_only else 4)
                        if rows[-1]['actual_HTTP_requests'] != expected_requests:
                            raise RuntimeError('Cold READY reopened origin or lost cancellation input')
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
        log_pids = {record.get('fixture_app_pid')}
        if record['case_results']:
            log_pids.add(str(record['case_results'][-1].get('source_pid', '')))
        log_pids.discard(None)
        log_pids.discard('')
        log = '\n'.join(adb('logcat', '-d', '-v', 'threadtime', '--pid', pid,
            required=False).stdout for pid in sorted(log_pids))
        record['fixture_log_pids'] = sorted(log_pids)
        record['fixture_uncaught_errors'] = sum('Unhandled Exception:' in line or
            'FATAL EXCEPTION:' in line for line in log.splitlines())
        (args.out / 'logcat.txt').write_text(log)
        if changed:
            adb('shell', 'am', 'force-stop', PACKAGE)
            adb('shell', 'run-as', PACKAGE, 'rm', '-rf', 'files/zic-source-native-webp-inputs')
            cleanup = adb('shell', 'run-as', PACKAGE, 'rm', '-f', REMOTE,
                REMOTE + '.trace.jsonl', required=False)
            record['fixture_device_results_removed'] = cleanup.returncode == 0
            install(args.restore_apk, record['restore_apk']['sha256'])
            adb('shell', 'am', 'start', '-W', '-n', PACKAGE + '/.MainActivity')
            record['ordinary_APK_restored'] = True
            record['ordinary_app_pid'] = adb('shell', 'pidof', PACKAGE).stdout.strip()
        save()
    if record.get('fixture_uncaught_errors'):
        raise RuntimeError('Fixture owner log contains uncaught errors: ' +
            str(record['fixture_uncaught_errors']))
    print('Actual source Pipeline cases passed; ordinary APK restored.', flush=True)


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Build/run real Binder body acceptance against prebuilt production APKs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import zipfile

CASES = (
    'normal', 'cancel-before-claim', 'cancel-during-hash', 'close-claim',
    'close-during-hash', 'session-close-read', 'source-loss', 'producer-loss',
    'host-stage', 'host-reopen', 'rpc-timeout',
)
INITIAL_EH_CASES = ('eh-initial-replay', 'eh-initial-terminal')
SOURCE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk-root', type=Path, default=Path(
        os.environ.get('ANDROID_SDK_ROOT', str(Path.home() / 'android-sdk'))))
    parser.add_argument('--keystore', type=Path,
        default=Path.home() / '.android/debug.keystore')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--run', action='store_true', help='Install and run the device fixture')
    parser.add_argument('--serial')
    parser.add_argument('--profile-apk', type=Path)
    parser.add_argument('--restore-apk', type=Path)
    parser.add_argument('--cases', nargs='+', choices=CASES + INITIAL_EH_CASES, default=list(CASES))
    args = parser.parse_args()
    if args.run and not all((args.serial, args.profile_apk, args.restore_apk)):
        parser.error('--run requires --serial, --profile-apk and --restore-apk')
    if 'host-stage' in args.cases or 'host-reopen' in args.cases:
        if not ('host-stage' in args.cases and 'host-reopen' in args.cases and
                args.cases.index('host-reopen') == args.cases.index('host-stage') + 1):
            parser.error('host-stage and host-reopen must run consecutively in that order')

    args.out.mkdir(parents=True, exist_ok=True)
    output = args.out.resolve()
    record = {'source_sha256': hashlib.sha256((SOURCE / 'BinderBodyProbe.java').read_bytes()).hexdigest(),
        'production_apk_rebuilt_or_modified': False, 'commands': [], 'cases': []}

    def save():
        (output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')

    def run(command, timeout=120):
        command = list(map(str, command))
        begin = time.time_ns()
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        record['commands'].append({'command': command, 'begin_ns': begin, 'end_ns': time.time_ns(),
            'exit_code': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr})
        save()
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        return result.stdout

    sdk = args.sdk_root.resolve()
    tools = sdk / 'build-tools/36.0.0'
    android = sdk / 'platforms/android-36/android.jar'
    for name in ('classes', 'dex'):
        shutil.rmtree(output / name, ignore_errors=True)
        (output / name).mkdir()
    run(['javac', '-source', '8', '-target', '8', '-classpath', android,
        '-d', output / 'classes', SOURCE / 'BinderBodyProbe.java'])
    run([tools / 'd8', '--lib', android, '--min-api', '24', '--output', output / 'dex'] +
        sorted((output / 'classes').rglob('*.class')))
    run([tools / 'aapt2', 'link', '-I', android, '--manifest', SOURCE / 'AndroidManifest.xml',
        '-o', output / 'unsigned.apk'])
    with zipfile.ZipFile(output / 'unsigned.apk', 'a') as apk:
        apk.write(output / 'dex/classes.dex', 'classes.dex')
    run([tools / 'zipalign', '-f', '4', output / 'unsigned.apk', output / 'aligned.apk'])
    run([tools / 'apksigner', 'sign', '--ks', args.keystore,
        '--ks-key-alias', 'androiddebugkey', '--ks-pass', 'pass:android', '--key-pass', 'pass:android',
        '--out', output / 'probe.apk', output / 'aligned.apk'])
    run([tools / 'apksigner', 'verify', output / 'probe.apk'])
    record['probe_apk_sha256'] = hashlib.sha256((output / 'probe.apk').read_bytes()).hexdigest()
    record['build_passed'] = True
    save()
    if not args.run:
        print('Fixture build passed:', output / 'probe.apk')
        return

    def adb(*command, timeout=120):
        return run([sdk / 'platform-tools/adb', '-s', args.serial, *command], timeout)

    def cert(apk):
        text = run([tools / 'apksigner', 'verify', '--print-certs', apk])
        values = re.findall(r'^Signer #\d+ certificate SHA-256 digest: (\w+)$', text, re.M)
        if len(values) != 1:
            raise RuntimeError('Expected one verified APK signing certificate')
        return values[0]

    for name in ('profile_apk', 'restore_apk'):
        apk = getattr(args, name).resolve()
        record[name] = {'path': str(apk), 'sha256': hashlib.sha256(apk.read_bytes()).hexdigest()}
    if len({cert(args.profile_apk), cert(args.restore_apk), cert(output / 'probe.apk')}) != 1:
        raise RuntimeError('Profile, restore APK and instrumentation must share their signing certificate')

    def install(apk, expected):
        text = adb('install', '-r', '-t', str(apk), timeout=180)
        if 'Success' not in text:
            raise RuntimeError(text)
        actual = adb('shell', 'pm', 'path', 'dev.zic.zic').strip().removeprefix('package:')
        if adb('shell', 'sha256sum', actual).split()[0] != expected:
            raise RuntimeError('Installed target APK does not match the supplied artifact')

    changed = False
    try:
        adb('shell', 'am', 'force-stop', 'dev.zic.zic')
        changed = True
        install(args.profile_apk, record['profile_apk']['sha256'])
        if 'Success' not in adb('install', '-r', '-t', str(output / 'probe.apk'), timeout=180):
            raise RuntimeError('Instrumentation installation failed')
        for case in args.cases:
            text = adb('shell', 'am', 'instrument', '-w', '-r', '-e', 'case', case,
                'dev.zic.binderbodyprobe/dev.zic.binderbodyprobe.BinderBodyProbe', timeout=135)
            (output / (case + '.txt')).write_text(text)
            values = [line.partition('INSTRUMENTATION_RESULT: evidence=')[2] for line in text.splitlines()
                if line.startswith('INSTRUMENTATION_RESULT: evidence=')]
            evidence = json.loads(values[0]) if len(values) == 1 else None
            record['cases'].append({'case': case, 'evidence': evidence,
                'instrumentation_success': 'INSTRUMENTATION_CODE: -1' in text})
            save()
            if not evidence or evidence.get('status') != 'passed' or 'INSTRUMENTATION_CODE: -1' not in text:
                raise RuntimeError('Fixture failed: ' + case + '\n' + text)
            print('Passed:', case, flush=True)
        record['all_selected_cases_passed'] = True
    finally:
        if changed:
            adb('shell', 'am', 'force-stop', 'dev.zic.zic')
            install(args.restore_apk, record['restore_apk']['sha256'])
            if 'Success' not in adb('uninstall', 'dev.zic.binderbodyprobe'):
                raise RuntimeError('Instrumentation removal failed')
            adb('shell', 'am', 'start', '-W', '-n', 'dev.zic.zic/.MainActivity')
            record['restore_apk_verified_and_probe_removed'] = True
        save()


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Prepare signed beta assets only after package/version/ABI identity checks."""
import argparse
import hashlib
import os
import re
import shutil
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ABIS = ('arm64-v8a', 'armeabi-v7a', 'x86_64')
# The existing public beta certificate: preserve Android upgrade compatibility.
BETA_CERTIFICATE = '5018611e9f75d09976b172835641d0282081d938a9e2015ff9824a723af7783d'


def beta_version(pubspec, properties):
    match = re.search(r'^version:\s*(\d+\.\d+\.\d+-beta\.\d+)\+([1-9]\d*)\s*$', pubspec, re.M)
    if not match:
        raise ValueError('App version must be an explicit beta with a positive build number')
    version, build = match.groups()
    android = dict(line.split('=', 1) for line in properties.splitlines()
                   if '=' in line and not line.lstrip().startswith('#'))
    if android.get('versionName') != version or android.get('versionCode') != build:
        raise ValueError('Android and Flutter package versions disagree')
    return version, build


def release_notes(changelog, version):
    heading = f'## {version}'
    lines = changelog.splitlines()
    if heading not in lines:
        raise ValueError(f'CHANGELOG is missing {heading}')
    start = lines.index(heading) + 1
    end = next((i for i in range(start, len(lines)) if lines[i].startswith('## ')), len(lines))
    notes = '\n'.join(lines[start:end]).strip()
    if not notes:
        raise ValueError('Release notes must not be empty')
    return notes + '\n'


def validate_badging(text, version, build):
    identity = re.search(r"^package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", text, re.M)
    if not identity or identity.groups() != ('dev.zic.zic', build, version):
        raise ValueError('APK package/version does not match this release')
    if re.search(r'^application-debuggable(?:\s|$)', text, re.M):
        raise ValueError('A debuggable APK cannot be published as the beta release')


def validate_certificate(text):
    certificates = re.findall(r'^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]+)$', text, re.M)
    if [s.lower() for s in certificates] != [BETA_CERTIFICATE]:
        raise ValueError('APK signing identity differs from the existing public beta')


def validate_native_layout(names, abi):
    libraries = [n for n in names if n.startswith('lib/') and n.endswith('.so')]
    if not libraries or any(len(n.split('/')) != 3 or n.split('/')[1] != abi for n in libraries):
        raise ValueError(f'APK is not a single {abi} split')
    for name in ('libapp.so', 'libflutter.so', 'libmedia_core.so', 'librhttp.so'):
        if f'lib/{abi}/{name}' not in libraries:
            raise ValueError(f'APK is missing {abi}/{name}')


def android_tools():
    sdk = os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME')
    if not sdk:
        raise ValueError('Android SDK is required to validate release packages')
    versions = [p for p in (Path(sdk) / 'build-tools').iterdir()
                if p.is_dir() and re.fullmatch(r'\d+\.\d+\.\d+', p.name)]
    tools = max(versions, key=lambda p: tuple(map(int, p.name.split('.'))))
    return tools / 'aapt', tools / 'apksigner'


def package(version, build, output):
    aapt, apksigner = android_tools()
    validated = []
    for abi in ABIS:
        apk = ROOT / f'apps/app/build/app/outputs/flutter-apk/app-{abi}-release.apk'
        badging = subprocess.check_output([str(aapt), 'dump', 'badging', str(apk)], text=True)
        validate_badging(badging, version, build)
        certificate = subprocess.check_output([str(apksigner), 'verify', '--print-certs', str(apk)], text=True)
        validate_certificate(certificate)
        with zipfile.ZipFile(apk) as archive:
            validate_native_layout(archive.namelist(), abi)
        validated.append((apk, f'zic-{version}-{abi}.apk'))
    output.mkdir(parents=True, exist_ok=False)
    checksums = []
    for apk, name in validated:
        target = output / name
        shutil.copyfile(apk, target)
        with target.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        checksums.append(f'{digest}  {name}')
    (output / 'SHA256SUMS').write_text('\n'.join(checksums) + '\n')
    print(f'Validated {version}+{build}: three release ABIs, existing signing identity and SHA256SUMS')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    metadata = sub.add_parser('metadata')
    metadata.add_argument('--github-output', type=Path, required=True)
    metadata.add_argument('--notes', type=Path, required=True)
    assets = sub.add_parser('package')
    assets.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    version, build = beta_version((ROOT / 'apps/app/pubspec.yaml').read_text(),
                                 (ROOT / 'apps/app/android/zic-version.properties').read_text())
    if args.command == 'metadata':
        args.notes.write_text(release_notes((ROOT / 'CHANGELOG.md').read_text(), version))
        with args.github_output.open('a') as output:
            output.write(f'version={version}\nbuild={build}\ntag=v{version}\n')
    else:
        package(version, build, args.output)


if __name__ == '__main__':
    main()

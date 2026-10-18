#!/usr/bin/env python3
"""Build only OCR's OpenCV modules, retaining the upstream Android fast paths."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
VERSION = '4.13.0'
COMMIT = 'fe38fc608f6acb8b68953438a62305d8318f4fcd'
AAR_SHA256 = 'a8c9b0929d8d6367bb476320a1f36587db2b57ea18d8f7521ce509514903ca04'
ARTIFACT_VERSION = f'{VERSION}-ocr1'
ARTIFACT = Path(f'maven/dev/zic/thirdparty/opencv-ocr/{ARTIFACT_VERSION}/opencv-ocr-{ARTIFACT_VERSION}')
AAR = ARTIFACT.parent / f'{ARTIFACT.name}.aar'
POM = ARTIFACT.parent / f'{ARTIFACT.name}.pom'
ABIS = ('arm64-v8a', 'armeabi-v7a', 'x86_64')
MODULES = ('core', 'imgproc', 'imgcodecs', 'photo', 'java')
JNI = re.compile(rb'Java_org_opencv_(?:(?:core|imgproc|imgcodecs|photo)_|android_Utils_)[A-Za-z0-9_]+')


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def valid_runtime(runtime: Path) -> bool:
    try:
        metadata = json.loads((runtime / 'versions.json').read_text())
        return (metadata['commit'] == COMMIT and metadata['modules'] == list(MODULES)
            and metadata['recipe_sha256'] == digest(Path(__file__))
            and metadata['aar_sha256'] == digest(runtime / AAR))
    except (OSError, ValueError, KeyError):
        return False


def validate_library(body: bytes, abi: str) -> None:
    modules = re.search(rb'To be built: +([^\r\n]+)', body)
    if modules is None or set(modules[1].decode().split()) != set(MODULES):
        raise RuntimeError(f'OpenCV module closure changed for {abi}')
    if not re.search(rb'Parallel framework: +TBB', body):
        raise RuntimeError(f'OpenCV TBB fast path missing for {abi}')
    hal = re.search(rb'Custom HAL: +YES \(([^\r\n]+)\)', body)
    accelerators = ('carotene', 'KleidiCV') if abi == 'arm64-v8a' else ('carotene',) if abi == 'armeabi-v7a' else ('ipp',)
    if hal is None or any(name.encode() not in hal[1] for name in accelerators):
        raise RuntimeError(f'OpenCV HAL fast path missing for {abi}')
    baseline = re.search(rb'Baseline: +([^\r\n]+)', body)
    features = ('SSE', 'SSE2', 'SSE3') if abi == 'x86_64' else ('NEON', 'FP16') if abi == 'arm64-v8a' else ('NEON',)
    if baseline is None or not set(features) <= set(baseline[1].decode().split()):
        raise RuntimeError(f'OpenCV SIMD baseline missing for {abi}')
    if abi != 'armeabi-v7a':
        dispatch = re.search(rb'Dispatched code generation: +([^\r\n]+)', body)
        features = ('SSE4_1', 'SSE4_2', 'AVX', 'FP16', 'AVX2', 'AVX512_SKX') if abi == 'x86_64' else ('NEON_DOTPROD', 'NEON_FP16', 'NEON_BF16')
        if dispatch is None or not set(features) <= set(dispatch[1].decode().split()):
            raise RuntimeError(f'OpenCV SIMD dispatch missing for {abi}')


def upstream_aar(native: Path) -> Path:
    cache = Path(os.environ.get('GRADLE_USER_HOME', Path.home() / '.gradle')) / 'caches/modules-2/files-2.1'
    candidates = list((cache / f'org.opencv/opencv/{VERSION}').glob(f'*/opencv-{VERSION}.aar'))
    candidates.append(native / f'downloads/opencv-{VERSION}.aar')
    for path in candidates:
        if path.is_file() and digest(path) == AAR_SHA256:
            return path
    target = candidates[-1]
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix('.downloading')
    try:
        url = f'https://repo.maven.apache.org/maven2/org/opencv/opencv/{VERSION}/opencv-{VERSION}.aar'
        with urllib.request.urlopen(url, timeout=60) as response, temporary.open('wb') as output:
            shutil.copyfileobj(response, output)
        if digest(temporary) != AAR_SHA256:
            raise RuntimeError('OpenCV upstream AAR checksum mismatch')
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
    return target


def build(native: Path, sdk: Path, jobs: int) -> None:
    source = native / 'opencv'
    if not source.exists():
        subprocess.run(['git', 'clone', '--filter=blob:none', '--depth=1', '--branch', VERSION,
            'https://github.com/opencv/opencv.git', str(source)], check=True)
    revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != COMMIT or subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain']):
        raise RuntimeError('OpenCV source must be the clean pinned revision')
    ndk = sdk / 'ndk/28.0.13004108'
    cmake = sdk / 'cmake/3.22.1/bin/cmake'
    ninja = sdk / 'cmake/3.22.1/bin/ninja'
    toolchain = ndk / 'build/cmake/android.toolchain.cmake'
    if not all(path.is_file() for path in (cmake, ninja, toolchain)):
        raise RuntimeError('OpenCV requires Android CMake 3.22.1 and NDK 28.0.13004108')
    runtime = native / 'opencv-runtime'
    with tempfile.TemporaryDirectory(prefix='opencv-runtime-', dir=native) as temporary:
        staging = Path(temporary)
        aar_path = staging / AAR
        aar_path.parent.mkdir(parents=True, exist_ok=True)
        original = upstream_aar(native)
        with zipfile.ZipFile(original) as upstream, zipfile.ZipFile(aar_path, 'w', zipfile.ZIP_DEFLATED) as aar:
            # Preserve the exact upstream Java API/resources. Only the native
            # module closure changes; Prefab C++ development files are not used.
            for item in upstream.infolist():
                if not item.is_dir() and not item.filename.startswith(('jni/', 'prefab/')):
                    aar.writestr(item, upstream.read(item.filename))
            for abi in ABIS:
                directory = native / f'build/opencv/{abi}'
                flags = [
                    f'-DCMAKE_MAKE_PROGRAM={ninja}', f'-DCMAKE_TOOLCHAIN_FILE={toolchain}',
                    f'-DANDROID_ABI={abi}', '-DANDROID_PLATFORM=android-24', '-DANDROID_STL=c++_shared',
                    '-DCMAKE_BUILD_TYPE=Release', '-DBUILD_SHARED_LIBS=OFF', '-DBUILD_FAT_JAVA_LIB=ON',
                    f'-DBUILD_LIST={",".join((*MODULES, "java_bindings_generator"))}',
                    '-DBUILD_JAVA=ON', '-DBUILD_ANDROID_PROJECTS=OFF',
                    '-DANDROID_PROJECTS_BUILD_TYPE=GRADLE', f'-DANDROID_SDK={sdk}',
                    '-DBUILD_TESTS=OFF', '-DBUILD_PERF_TESTS=OFF', '-DBUILD_EXAMPLES=OFF',
                    '-DBUILD_ANDROID_EXAMPLES=OFF', '-DINSTALL_ANDROID_EXAMPLES=OFF',
                    '-DBUILD_opencv_apps=OFF', '-DBUILD_WITH_DEBUG_INFO=OFF',
                    '-DCV_ENABLE_INTRINSICS=ON', '-DCV_DISABLE_OPTIMIZATION=OFF',
                    '-DWITH_TBB=ON', '-DBUILD_TBB=ON',
                    f'-DWITH_CAROTENE={"OFF" if abi == "x86_64" else "ON"}',
                    f'-DWITH_KLEIDICV={"ON" if abi == "arm64-v8a" else "OFF"}',
                    f'-DWITH_IPP={"ON" if abi == "x86_64" else "OFF"}',
                    '-DWITH_OPENCL=OFF', '-DWITH_AVIF=OFF', '-DBUILD_OPENEXR=ON',
                    '-DOPENCV_LICENSES_INSTALL_PATH=licenses',
                ]
                if abi == 'arm64-v8a':
                    flags += ['-DCPU_BASELINE=DETECT', '-DCPU_DISPATCH=NEON_FP16,NEON_BF16,NEON_DOTPROD']
                elif abi == 'armeabi-v7a':
                    flags += ['-DANDROID_ARM_NEON=ON', '-DCPU_BASELINE=DETECT']
                else:
                    flags += ['-DCPU_BASELINE=SSE3', '-DCPU_DISPATCH=SSE4_1,SSE4_2,AVX,FP16,AVX2,AVX512_SKX']
                subprocess.run([str(cmake), '-S', str(source), '-B', str(directory), '-G', 'Ninja', *flags], check=True)
                subprocess.run([str(cmake), '--build', str(directory), '--target', 'opencv_java', '-j', str(jobs)], check=True)
                subprocess.run([str(cmake), '--install', str(directory), '--component', 'licenses',
                    '--prefix', str(staging)], check=True)
                body = (directory / f'jni/{abi}/libopencv_java4.so').read_bytes()
                required = set(JNI.findall(upstream.read(f'jni/{abi}/libopencv_java4.so')))
                if required != set(JNI.findall(body)):
                    raise RuntimeError(f'OpenCV OCR JNI surface changed for {abi}')
                validate_library(body, abi)
                aar.writestr(f'jni/{abi}/libopencv_java4.so', body)
                triple = {'arm64-v8a': 'aarch64-linux-android',
                    'armeabi-v7a': 'arm-linux-androideabi', 'x86_64': 'x86_64-linux-android'}[abi]
                stdlib, = ndk.glob(f'toolchains/llvm/prebuilt/*/sysroot/usr/lib/{triple}/libc++_shared.so')
                # One shared STL serves OpenCV and the local translation JNI.
                aar.write(stdlib, f'jni/{abi}/libc++_shared.so')
                print(f'OpenCV OCR {abi}: {len(body)} bytes; JNI/parallel/HAL checks pass', flush=True)
            shutil.copyfile(source / 'LICENSE', staging / 'licenses/opencv.txt')
            for path in sorted((staging / 'licenses').iterdir()):
                aar.write(path, f'assets/third_party/comic_translation/opencv/{path.name}')
        (staging / POM).write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>dev.zic.thirdparty</groupId><artifactId>opencv-ocr</artifactId>
  <version>{ARTIFACT_VERSION}</version><packaging>aar</packaging>
  <name>OpenCV OCR module closure</name>
  <dependencies><dependency><groupId>org.jetbrains.kotlin</groupId>
    <artifactId>kotlin-stdlib-jdk8</artifactId><version>1.5.20</version>
  </dependency></dependencies>
</project>
''')
        (staging / 'versions.json').write_text(json.dumps({
            'version': VERSION, 'commit': COMMIT, 'modules': MODULES, 'abis': ABIS,
            'upstream_aar_sha256': AAR_SHA256, 'recipe_sha256': digest(Path(__file__)),
            'aar_sha256': digest(aar_path),
        }, indent=2) + '\n')
        # Publish a complete package only after every ABI and binding passes.
        previous = native / 'opencv-runtime.previous'
        if previous.exists():
            raise RuntimeError(f'Unexpected interrupted OpenCV package: {previous}')
        if runtime.exists():
            runtime.rename(previous)
        try:
            staging.rename(runtime)
        except BaseException:
            if previous.exists():
                previous.rename(runtime)
            raise
        if previous.exists():
            shutil.rmtree(previous)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native-root', type=Path, default=Path(os.environ.get('ZIC_TRANSLATION_NATIVE_ROOT', ROOT / '.deps/comic_translation_native')))
    parser.add_argument('--android-sdk', type=Path, default=Path(os.environ.get('ANDROID_SDK_ROOT', os.environ.get('ANDROID_HOME', ''))))
    parser.add_argument('--jobs', type=int, default=int(os.environ.get('ZIC_TRANSLATION_BUILD_JOBS', '4')))
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    sdk = args.android_sdk
    if sdk == Path('.'):
        properties = (ROOT / 'apps/app/android/local.properties').read_text()
        sdk = Path(re.search(r'^sdk.dir=(.+)$', properties, re.M)[1])
    native = args.native_root.resolve()
    native.mkdir(parents=True, exist_ok=True)
    if not valid_runtime(native / 'opencv-runtime'):
        build(native, sdk.resolve(), args.jobs)
    if not valid_runtime(native / 'opencv-runtime'):
        raise RuntimeError('OpenCV OCR package is invalid')
    print('Android OpenCV: pinned OCR modules and optimized fast paths available')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Check actual APK closure for the migrated Android translation backends."""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def dex_classes(body: bytes) -> set[str]:
    assert body.startswith(b'dex\n')
    _, strings = struct.unpack_from('<II', body, 0x38)
    _, types = struct.unpack_from('<II', body, 0x40)
    count, definitions = struct.unpack_from('<II', body, 0x60)
    names = set()
    for index in range(count):
        class_id, = struct.unpack_from('<I', body, definitions + index * 32)
        string_id, = struct.unpack_from('<I', body, types + class_id * 4)
        offset, = struct.unpack_from('<I', body, strings + string_id * 4)
        while body[offset] & 0x80:
            offset += 1
        offset += 1
        names.add(body[offset:body.index(b'\0', offset)].decode('utf-8'))
    return names


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--apk', type=Path, required=True)
    args = parser.parse_args()
    required = [
        'zic_translation_cpu', 'zic_translation', 'zic_hymt', 'ctranslate2', 'sentencepiece',
        'llama', 'ggml', 'ggml-base', 'ggml-cpu', 'onnxruntime',
        'onnxruntime4j_jni', 'opencv_java4', 'c++_shared',
    ]
    with zipfile.ZipFile(args.apk) as apk:
        classes = set()
        for name in apk.namelist():
            if name.startswith('classes') and name.endswith('.dex'):
                classes.update(dex_classes(apk.read(name)))
        for name in ['ComicTranslationPlugin', 'LocalTranslationNative', 'LocalHyMtNative', 'LocalTranslationCpu']:
            descriptor = f'Ldev/zic/comic_translation/{name};'
            assert descriptor in classes, f'Missing unrenamed Android entry: {descriptor}'
        for name in [
            'TensorInfo', 'TensorInfo$OnnxTensorType', 'OnnxJavaType',
            'OnnxTensor', 'OnnxMap', 'OnnxSequence', 'MapInfo', 'SequenceInfo',
        ]:
            descriptor = f'Lai/onnxruntime/{name};'
            assert descriptor in classes, f'Missing unrenamed ONNX JNI type: {descriptor}'
        for library in required:
            name = f'lib/arm64-v8a/lib{library}.so'
            body = apk.read(name)
            assert body[:6] == b'\x7fELF\x02\x01', name
            assert struct.unpack_from('<H', body, 18)[0] == 183, name
        for library, native in [('zic_translation', 'LocalTranslationNative'), ('zic_hymt', 'LocalHyMtNative')]:
            body = apk.read(f'lib/arm64-v8a/lib{library}.so')
            for method in ['create', 'translate', 'destroy']:
                assert f'Java_dev_zic_comic_1translation_{native}_{method}'.encode() in body, (library, method)
        probe = apk.read('lib/arm64-v8a/libzic_translation_cpu.so')
        assert b'Java_dev_zic_comic_1translation_LocalTranslationCpu_capabilities' in probe
        assert apk.read('assets/flutter_assets/packages/comic_translation/assets/opencc.txt')
        notices = 'assets/third_party/comic_translation'
        versions = json.loads(apk.read(f'{notices}/versions.json'))
        assert versions['llama']['commit'] == '031ddb2e08962837c899374297da75f91cc0157d'
        patch = ROOT / 'tool/comic_translation/patches/llama-q2_0c-kleidiai.patch'
        assert versions['llama']['patch_sha256'] == hashlib.sha256(patch.read_bytes()).hexdigest()
        for name in ['kleidiai-Apache-2.0.txt', 'kleidiai-BSD-3-Clause.txt']:
            assert apk.read(f'{notices}/dependencies/{name}')
        assert apk.read('assets/third_party/comic_translation/vibevenera-LICENSE')
        assert apk.read('assets/third_party/comic_translation/ppocr-LICENSE')
    print('Android translation APK closure: OCR, JNI, Hy-MT, CTranslate2, OpenCC and notices OK')


if __name__ == '__main__':
    main()

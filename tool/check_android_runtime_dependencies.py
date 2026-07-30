#!/usr/bin/env python3
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GRADLE = ROOT / 'packages/plugin_host_bridge/android/build.gradle'
RULES = ROOT / 'packages/plugin_host_bridge/android/consumer-rules.pro'


class DependencyContractError(ValueError):
    pass


def validate_contract(gradle: str, rules: str) -> None:
    abi_block = re.search(
        r'runtimeOnly\("com\.github\.keiyoushi:extensions-lib:6e0c96cea8"\)\s*\{(?P<body>.*?)\n\s*\}',
        gradle,
        re.DOTALL,
    )
    if abi_block is None or 'transitive = false' not in abi_block.group('body'):
        raise DependencyContractError(
            'extensions-lib must be an ABI-only, non-transitive dependency',
        )

    forbidden = (
        'androidx.preference:preference:',
        'androidx.preference:preference-ktx:',
        'uy.kohesive.injekt:injekt-core:',
        'uy.kohesive.injekt:injekt-api:',
    )
    for coordinate in forbidden:
        if coordinate in gradle:
            raise DependencyContractError(
                f'duplicate host provider is declared: {coordinate}',
            )

    required = (
        'com.github.null2264.injekt:injekt-core:4135455a2a',
        'com.github.zhanghai.quickjs-java:quickjs-android:547f5b1597',
        'consumerProguardFiles "consumer-rules.pro"',
    )
    for value in required:
        if gradle.count(value) != 1:
            raise DependencyContractError(
                f'expected exactly one declaration of {value}',
            )

    for namespace in (
        'eu.kanade.tachiyomi.**',
        'androidx.preference.**',
        'uy.kohesive.injekt.**',
        'okhttp3.**',
        'kotlinx.coroutines.**',
        'kotlinx.serialization.**',
        'org.jsoup.**',
        'com.google.gson.**',
        'Signature,InnerClasses,EnclosingMethod,*Annotation*',
    ):
        if namespace not in rules:
            raise DependencyContractError(
                f'minified runtime does not retain {namespace}',
            )


def main() -> int:
    try:
        validate_contract(
            GRADLE.read_text(encoding='utf-8'),
            RULES.read_text(encoding='utf-8'),
        )
    except DependencyContractError as error:
        raise SystemExit(
            f'Android external-runtime dependency check failed: {error}',
        ) from error
    print('Android external-runtime dependency closure: OK')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

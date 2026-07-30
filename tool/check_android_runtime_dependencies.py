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
    # Neither incompatible Source ABI may enter the App runtime classpath.
    if 'runtimeOnly("com.github.keiyoushi:extensions-lib:' in gradle or \
       'implementation("com.github.keiyoushi:extensions-lib:' in gradle:
        raise DependencyContractError('Mihon Source ABI leaked onto the App runtime classpath')

    for configuration, coordinate in (
        ('mihonAbi14', 'com.github.keiyoushi:extensions-lib:18a8e26be2'),
        ('mihonAbi16', 'com.github.keiyoushi:extensions-lib:6e0c96cea8'),
    ):
        declaration = re.search(
            rf'{configuration}\("{re.escape(coordinate)}"\)\s*\{{(?P<body>.*?)\n\s*\}}',
            gradle,
            re.DOTALL,
        )
        if gradle.count(configuration) < 3 or gradle.count(coordinate) != 1 or declaration is None:
            raise DependencyContractError(
                f'missing isolated Mihon ABI asset input: {configuration} {coordinate}',
            )
        if 'transitive = false' not in declaration.group('body'):
            raise DependencyContractError(f'{configuration} must be non-transitive')
    for required in (
        'generateMihonAbiAssets',
        'assets.srcDir mihonAbiAssetsRoot',
        'mihon/abi/manifest.properties',
        'd8',
        'transitive = false',
    ):
        if required not in gradle:
            raise DependencyContractError(f'Mihon ABI asset generation is incomplete: {required}')

    forbidden = (
        'androidx.preference:preference-ktx:',
        'uy.kohesive.injekt:injekt-core:',
        'uy.kohesive.injekt:injekt-api:',
    )
    parent_declarations = tuple(
        line.strip()
        for line in gradle.splitlines()
        if line.strip().startswith(('api ', 'implementation ', 'runtimeOnly '))
    )
    for coordinate in forbidden:
        if any(coordinate in line for line in parent_declarations):
            raise DependencyContractError(f'duplicate host provider is declared: {coordinate}')

    required = (
        'androidx.preference:preference:1.2.1',
        'com.github.null2264.injekt:injekt-core:4135455a2a',
        'com.github.zhanghai.quickjs-java:quickjs-android:547f5b1597',
        'consumerProguardFiles "consumer-rules.pro"',
    )
    for value in required:
        if gradle.count(value) != 1:
            raise DependencyContractError(f'expected exactly one declaration of {value}')
    for value in (
        'mihonRuntime14Sources',
        'mihonRuntime16Sources',
        'mihonRuntimeCommonSources',
        'entry.name in overrides',
        'still contains a throwing compile stub',
    ):
        if value not in gradle:
            raise DependencyContractError(f'functional Mihon ABI generation is missing: {value}')

    for absent in ('eu.kanade.tachiyomi.**',):
        if absent in rules:
            raise DependencyContractError(f'isolated ABI namespace must not be retained in parent: {absent}')
    for namespace in (
        'androidx.preference.**',
        'okhttp3.**',
        'kotlinx.coroutines.**',
        'kotlinx.serialization.**',
        'org.jsoup.**',
        'com.google.gson.**',
        'Signature,InnerClasses,EnclosingMethod,*Annotation*',
    ):
        if namespace not in rules:
            raise DependencyContractError(f'minified common runtime does not retain {namespace}')
        if namespace != 'Signature,InnerClasses,EnclosingMethod,*Annotation*':
            if f'-keep class {namespace}' not in rules:
                raise DependencyContractError(
                    f'dynamic common runtime still permits whole-program optimization: {namespace}',
                )


def main() -> int:
    try:
        validate_contract(GRADLE.read_text(), RULES.read_text())
    except DependencyContractError as error:
        raise SystemExit(f'Android external-runtime dependency check failed: {error}') from error
    print('Android version-isolated external-runtime dependency closure: OK')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

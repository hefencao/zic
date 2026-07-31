#!/usr/bin/env python3
from __future__ import annotations

from check_android_runtime_dependencies import DependencyContractError, GRADLE, RULES, validate_contract


def _must_fail(gradle: str, rules: str, expected: str) -> None:
    try:
        validate_contract(gradle, rules)
    except DependencyContractError as error:
        assert expected in str(error), (expected, str(error))
    else:
        raise AssertionError(f'contract mutation unexpectedly passed: {expected}')


def main() -> int:
    gradle = GRADLE.read_text()
    rules = RULES.read_text()
    validate_contract(gradle, rules)

    _must_fail(
        gradle.replace('mihonAbi14("com.github.keiyoushi:extensions-lib:18a8e26be2")',
                       'mihonAbi14("com.github.keiyoushi:extensions-lib:6e0c96cea8")'),
        rules,
        '18a8e26be2',
    )
    _must_fail(
        gradle.replace(
            'mihonAbi14("com.github.keiyoushi:extensions-lib:18a8e26be2") {\n        transitive = false\n    }',
            'mihonAbi14("com.github.keiyoushi:extensions-lib:18a8e26be2") {\n    }',
        ),
        rules,
        'mihonAbi14 must be non-transitive',
    )
    _must_fail(
        gradle.replace('    runtimeOnly "org.jetbrains.kotlin:kotlin-stdlib-jdk8:2.4.10"\n',
                       '    runtimeOnly("com.github.keiyoushi:extensions-lib:6e0c96cea8")\n'
                       '    runtimeOnly "org.jetbrains.kotlin:kotlin-stdlib-jdk8:2.4.10"\n'),
        rules,
        'leaked onto the App runtime classpath',
    )
    _must_fail(
        gradle.replace('    runtimeOnly "com.google.code.gson:gson:2.11.0"\n',
                       '    runtimeOnly "com.google.code.gson:gson:2.11.0"\n'
                       '    runtimeOnly "androidx.preference:preference-ktx:1.2.1"\n'),
        rules,
        'duplicate host provider',
    )
    _must_fail(
        gradle,
        rules.replace('-keep class okhttp3.** { *; }\n', ''),
        'does not retain okhttp3.**',
    )
    print('Android version-isolated dependency mutations: OK')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

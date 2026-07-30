#!/usr/bin/env python3
from __future__ import annotations

from check_android_runtime_dependencies import (
    DependencyContractError,
    GRADLE,
    RULES,
    validate_contract,
)


def _must_fail(gradle: str, rules: str, expected: str) -> None:
    try:
        validate_contract(gradle, rules)
    except DependencyContractError as error:
        assert expected in str(error), (expected, str(error))
    else:
        raise AssertionError(f'contract mutation unexpectedly passed: {expected}')


def main() -> int:
    gradle = GRADLE.read_text(encoding='utf-8')
    rules = RULES.read_text(encoding='utf-8')
    validate_contract(gradle, rules)

    _must_fail(
        gradle.replace('        transitive = false\n', ''),
        rules,
        'non-transitive',
    )
    _must_fail(
        gradle.replace(
            '    runtimeOnly "com.google.code.gson:gson:2.11.0"\n',
            '    runtimeOnly "com.google.code.gson:gson:2.11.0"\n'
            '    runtimeOnly "androidx.preference:preference-ktx:1.2.1"\n',
        ),
        rules,
        'duplicate host provider',
    )
    _must_fail(
        gradle.replace(
            '    runtimeOnly "io.reactivex:rxjava:1.3.8"\n',
            '    runtimeOnly "uy.kohesive.injekt:injekt-core:1.16.1"\n'
            '    runtimeOnly "io.reactivex:rxjava:1.3.8"\n',
        ),
        rules,
        'duplicate host provider',
    )
    _must_fail(
        gradle,
        rules.replace(
            '-keep,allowoptimization class eu.kanade.tachiyomi.** { *; }\n',
            '',
        ),
        'does not retain eu.kanade.tachiyomi.**',
    )

    print('Android external-runtime dependency mutations: OK')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

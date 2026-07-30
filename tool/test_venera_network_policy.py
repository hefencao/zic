#!/usr/bin/env python3
from __future__ import annotations

import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraRuntimeDriver.kt'


def extract(pattern: str, source: str, label: str) -> str:
    match = re.search(pattern, source, re.S)
    if not match:
        raise SystemExit(f'{label} helper not found')
    return match.group(0)


def main() -> int:
    kotlinc = shutil.which('kotlinc')
    java = shutil.which('java')
    if not kotlinc or not java:
        print('SKIP: kotlinc/java are not installed for Venera network helper execution')
        return 0

    source = SOURCE.read_text(encoding='utf-8')
    normalize = extract(
        r'internal fun normalizeVeneraAcceptEncoding\(.*?\n}\n',
        source,
        'normalizeVeneraAcceptEncoding',
    )
    safe_address = extract(
        r'internal fun isSafeVeneraPublicAddress\(.*?\n\s*!address\.isMulticastAddress\n',
        source,
        'isSafeVeneraPublicAddress',
    )
    kotlin = f'''package dev.zic.pluginhost

import java.net.InetAddress
import java.util.Locale

{normalize}
{safe_address}

fun main() {{
    check(normalizeVeneraAcceptEncoding(null) == "gzip, deflate")
    check(normalizeVeneraAcceptEncoding("gzip, deflate, br, zstd") == "gzip, deflate")
    check(normalizeVeneraAcceptEncoding("x-gzip, br") == "gzip")
    check(!isSafeVeneraPublicAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1))))
    check(!isSafeVeneraPublicAddress(InetAddress.getByAddress(byteArrayOf(10, 0, 0, 1))))
    check(isSafeVeneraPublicAddress(InetAddress.getByAddress(byteArrayOf(1, 1, 1, 1))))
    println("Venera network policy helpers: OK")
}}
'''
    with tempfile.TemporaryDirectory() as raw_temp:
        temp = Path(raw_temp)
        source_path = temp / 'VeneraNetworkPolicySmoke.kt'
        jar_path = temp / 'venera-network-policy.jar'
        source_path.write_text(kotlin, encoding='utf-8')
        subprocess.run(
            [kotlinc, str(source_path), '-include-runtime', '-d', str(jar_path)],
            check=True,
        )
        subprocess.run([java, '-jar', str(jar_path)], check=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

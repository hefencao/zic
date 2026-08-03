#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def lock_values() -> dict[str, str]:
    values: dict[str, str] = {}
    for line in (ROOT / 'native/libwebp.lock').read_text(encoding='utf-8').splitlines():
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        values[key] = value
    return values


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def run(command: list[str], *, env: dict[str, str], expect_ok: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if expect_ok and result.returncode != 0:
        raise SystemExit(
            'FAIL: command failed: ' + ' '.join(command) + '\n'
            + result.stdout + result.stderr
        )
    if not expect_ok and result.returncode == 0:
        raise SystemExit('FAIL: command unexpectedly succeeded: ' + ' '.join(command))
    return result


values = lock_values()
archive = ROOT / values['WEBP_ARCHIVE_PATH']
if not archive.is_file():
    raise SystemExit(f'FAIL: retained libwebp archive is missing: {archive}')
if sha256(archive) != values['WEBP_ARCHIVE_SHA256']:
    raise SystemExit('FAIL: retained libwebp archive sha256 does not match lock')
if (ROOT / 'tool/apply_libwebp_vp8_tls_patch.py').exists():
    raise SystemExit('FAIL: obsolete function-anchor libwebp transformer still exists')

with tempfile.TemporaryDirectory(prefix='zic-dev98-libwebp-') as directory:
    temp = Path(directory)
    deps = temp / 'deps'
    env = os.environ.copy()
    env['ZIC_DEPS_DIR'] = str(deps)
    env.pop('ZIC_WEBP_SOURCE', None)
    env.pop('ZIC_WEBP_ARCHIVE', None)
    env.pop('ZIC_WEBP_ALLOW_UNPINNED', None)

    fetched = run(['bash', 'tool/fetch_webp.sh'], env=env).stdout.strip()
    source = Path(fetched)
    if not source.is_dir() or '\n' in fetched:
        raise SystemExit(f'FAIL: fetch_webp returned an invalid source path: {fetched!r}')
    vp8 = source / 'src/dec/vp8_dec.c'
    if sha256(vp8) != values['WEBP_VP8_DEC_SHA256']:
        raise SystemExit('FAIL: extracted library source is not the locked clean source')

    # The upstream cache is tool-owned and immutable. A local mutation must be
    # repaired from the retained archive instead of reaching the patch stage.
    vp8.write_text(vp8.read_text(encoding='utf-8') + '\n// stale mutation\n', encoding='utf-8')
    repaired_result = run(['bash', 'tool/fetch_webp.sh'], env=env)
    repaired = Path(repaired_result.stdout.strip())
    if repaired != source or sha256(repaired / 'src/dec/vp8_dec.c') != values['WEBP_VP8_DEC_SHA256']:
        raise SystemExit('FAIL: corrupted upstream cache was not rebuilt from the archive')
    if 'rebuilding corrupted libwebp upstream cache' not in repaired_result.stderr:
        raise SystemExit('FAIL: upstream cache repair was not reported')

    first = run(['bash', 'tool/prepare_webp.sh'], env=env).stdout.strip()
    second = run(['bash', 'tool/prepare_webp.sh'], env=env).stdout.strip()
    if first != second or '\n' in first:
        raise SystemExit('FAIL: prepare_webp must return one stable prepared path')
    prepared_vp8 = Path(first) / 'src/dec/vp8_dec.c'
    run(['python3', 'tool/verify_libwebp_vp8_tls_patch.py', str(prepared_vp8)], env=env)
    for suffix in ('*.rej', '*.orig'):
        if list(Path(first).rglob(suffix)):
            raise SystemExit(f'FAIL: prepared source contains {suffix} files')

    # Explicit modified sources fail at source validation. They must never
    # produce the former misleading "VP8Clear anchor found 0" error.
    modified = temp / 'modified-source'
    shutil.copytree(source, modified)
    modified_vp8 = modified / 'src/dec/vp8_dec.c'
    modified_vp8.write_text(
        modified_vp8.read_text(encoding='utf-8').replace(
            'WebPSafeFree(dec->mem);',
            'VP8MemPoolReturn(dec->mem);',
            1,
        ),
        encoding='utf-8',
    )
    modified_env = env.copy()
    modified_env['ZIC_WEBP_SOURCE'] = str(modified)
    rejected = run(['bash', 'tool/prepare_webp.sh'], env=modified_env, expect_ok=False)
    diagnostics = rejected.stdout + rejected.stderr
    if 'not the clean pinned v1.6.0 tree' not in diagnostics:
        raise SystemExit('FAIL: modified source rejection does not identify source drift')
    if 'anchor' in diagnostics:
        raise SystemExit('FAIL: modified source leaked the rejected function-anchor failure mode')

required_docs = {
    'docs/adr/0082-pinned-libwebp-archive-and-exact-patch.md': '0.31.0-dev.98',
    'docs/audits/dev98-libwebp-source-patch-audit.md': '被否决方案清单',
    'docs/audits/dev98-validation-results.md': 'libwebp incremental and loop fixtures: OK',
}
for relative, token in required_docs.items():
    text = (ROOT / relative).read_text(encoding='utf-8')
    if token not in text:
        raise SystemExit(f'FAIL: {relative} missing {token!r}')
if 'test_dev98_libwebp_archive_prepare.py' not in (ROOT / 'tool/check.sh').read_text(encoding='utf-8'):
    raise SystemExit('FAIL: dev.98 gate is not wired into tool/check.sh')

print('dev.98 pinned libwebp archive and exact patch preparation: OK')

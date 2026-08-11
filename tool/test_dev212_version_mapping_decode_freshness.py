#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'missing {label}: {token}')


def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'superseded {label}: {token}')


catalog = read('packages/catalog/lib/src/source_catalog.dart')
for token in (
    "final verifiedAtValue = json['verifiedAt'];",
    'DateTime.tryParse(verifiedAtValue)',
    'verifiedAt: verifiedAt,',
):
    require(catalog, token, 'typed mapping verifiedAt decode')
forbid(catalog, 'DateTime.parse(verifiedAt)', 'Object-typed verifiedAt parse')

migration = read('apps/app/lib/demo_home_source_migration.dart')
for token in (
    'const Duration _versionPageMappingRevalidationInterval = Duration(minutes: 10);',
    'bool _versionPageMappingsAreFresh(',
    'if (_versionPageMappingsAreFresh(relation, DateTime.now().toUtc())) {',
    'final versions = await versionSource.findComicVersions(comicId);',
    'await _reuseSourceVersionDurablePartials(entry);',
):
    require(migration, token, 'version mapping freshness ownership')

catalog_test = read('packages/catalog/test/imported_library_store_test.dart')
for token in (
    'comic version page mapping parses verified time strictly',
    "'verifiedAt': 'not-a-date'",
    'throwsFormatException',
):
    require(catalog_test, token, 'mapping decode regression coverage')

check = read('tool/check.sh')
require(check, 'test_dev212_version_mapping_decode_freshness.py', 'release gate wiring')

print('dev.212 version mapping decode/freshness contract: OK')

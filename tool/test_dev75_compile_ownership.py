#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(source: str, token: str, message: str) -> None:
    if token not in source:
        raise SystemExit(f'ERROR: {message}: missing {token!r}')


def forbid(source: str, token: str, message: str) -> None:
    if token in source:
        raise SystemExit(f'ERROR: {message}: found {token!r}')


home_widgets = read('apps/app/lib/home_widgets.dart')
demo_home = read('apps/app/lib/demo_home.dart')
library_ui_test = read('apps/app/test/library_ui_test.dart')
misc_settings_test = read('apps/app/test/misc_settings_test.dart')
source_gateway_test = read('apps/app/test/source_resource_gateway_test.dart')
webp_demo_test = read('apps/app/test/webp_demo_test.dart')
pipeline_test = read('packages/pipeline/test/pipeline_test.dart')
reader_runtime = read('packages/reader_runtime/lib/reader_runtime.dart')
check_repo = read('tool/check_repo.py')
analyze = read('tool/analyze.sh')
flutter_tests = read('tool/test_flutter.sh')
check_script = read('tool/check.sh')
iteration_prompt = read('docs/AI_ITERATION_PROMPT.md')

forbid(
    home_widgets,
    'final class ComicDetailsScreen',
    'dead local-details compatibility wrapper must stay removed',
)
forbid(
    demo_home,
    'ComicDetailsScreen,',
    'DemoHome must not export the removed compatibility wrapper',
)
require(
    library_ui_test,
    'details.LocalComicDetailsScreen(',
    'details tests must exercise the actual lifecycle owner',
)
require(
    misc_settings_test,
    "import 'package:zic/reader_preferences.dart';",
    'extension methods require an explicit import',
)
require(
    source_gateway_test,
    "import 'package:domain/domain.dart';",
    'domain-owned ComicManifest must be imported from domain',
)
forbid(
    webp_demo_test,
    'readerPageDownloadId(',
    'App media tests must not duplicate downloads identity ownership',
)
forbid(
    pipeline_test,
    'currentCoverage: const Coverage(',
    'Coverage constructor is not const',
)
forbid(
    reader_runtime,
    "export 'src/asset_bundle_transport.dart';",
    'Reader runtime must not re-export Pipeline internal transport',
)
if (ROOT / 'apps/app/lib/asset_bundle_transport.dart').exists():
    raise SystemExit('ERROR: obsolete App AssetBundleTransport facade still exists')
if (ROOT / 'packages/reader_runtime/lib/src/asset_bundle_transport.dart').exists():
    raise SystemExit('ERROR: obsolete Reader AssetBundleTransport facade still exists')
if (ROOT / 'apps/app/test/asset_bundle_transport_test.dart').exists():
    raise SystemExit('ERROR: AssetBundleTransport test still lives in the App package')
if not (ROOT / 'packages/pipeline_runtime/test/asset_bundle_transport_test.dart').is_file():
    raise SystemExit('ERROR: Pipeline-owned AssetBundleTransport test is missing')
if not (ROOT / 'packages/local_media_ui/test/package_compile_test.dart').is_file():
    raise SystemExit('ERROR: local_media_ui package compile smoke test is missing')
require(
    check_repo,
    "ROOT / 'packages/pipeline_runtime/test/asset_bundle_transport_test.dart'",
    'repository gate must follow test ownership',
)

for package in (
    'packages/pipeline_runtime',
    'packages/reader_runtime',
    'packages/local_media_ui',
):
    require(analyze, package, 'Flutter analyzer coverage is incomplete')
    require(flutter_tests, package, 'Flutter test coverage is incomplete')
forbid(
    check_script,
    'dart format apps packages',
    'repository check must respect AGENTS.md and avoid formatting sources',
)
for required in (
    'Architecture 与所有权原则',
    '耦合审查必须覆盖',
    '被否决方案清单',
    '不得为了通过测试随意改变产品逻辑',
):
    require(iteration_prompt, required, 'future iteration prompt is incomplete')

print('dev.75 compile and ownership migration: OK')

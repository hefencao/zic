from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'missing {label}: {token}')


browser = read('apps/app/lib/source_browser.dart')
views = read('apps/app/lib/home_shell_views.dart')
tests = read('apps/app/test/source_browser_test.dart')
check = read('tool/check.sh')

for token in (
    'final BrowsableComicSource? Function(String sourceId)? resolveSource;',
    'final resolved = widget.resolveSource?.call(id);',
    "'verification-runtime-replaced'",
    'final replacement = _activeSource;',
    'final recovered = await _loadSource(',
    'allowVerificationFallback: false,',
    'browseOffset: _pageOffset,',
    'if (!_recoveringSourceAccess) {',
):
    require(browser, token, 'live runtime source recovery')

require(views, 'resolveSource: _sourceForId,', 'composition source resolver')
for token in (
    "verification retry resolves the replacement runtime source",
    'current = replacement;',
    'replacement.browseCalls, greaterThanOrEqualTo(1)',
):
    require(tests, token, 'replacement runtime owner test')
require(check, 'test_dev151_source_verification_runtime_replacement.py', 'check integration')
print('dev.151 source verification runtime replacement: OK')

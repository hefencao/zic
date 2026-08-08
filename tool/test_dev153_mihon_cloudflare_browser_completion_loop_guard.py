#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'FAIL: {path} missing dev.153 tokens: {missing}')


def forbid(path: str, *tokens: str) -> None:
    text = read(path)
    found = [token for token in tokens if token in text]
    if found:
        raise SystemExit(f'FAIL: {path} contains superseded Cloudflare tokens: {found}')


require(
    'packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/NetworkBrowserSnapshotStore.kt',
    'val preserveExisting = existing?.let',
    'sameSiteHost(existingHost, requestedHost)',
    'snapshot.optString(KEY_USER_AGENT).trim() == normalizedUserAgent',
    'if (!preserveExisting)',
    'Opening a verification browser must not erase a still-valid handoff',
    'if (!cookieHeader.isNullOrBlank() || snapshot.optString(KEY_COOKIE_HEADER).isBlank())',
)

activity = 'packages/network_bridge/android/src/main/kotlin/dev/zic/network/NetworkBrowserActivity.kt'
require(
    activity,
    'verificationPageResolved',
    'sameSiteWithRequestedUrl(currentUrl)',
    'mergeCookieHeaders(',
)
forbid(
    activity,
    'clearCloudflareClearance(',
    'Cloudflare verification did not produce cf_clearance',
    "challenge-platform')>=0",
    "cf-chl-')>=0",
)

classifier = 'packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/AndroidCloudflareInterceptor.kt'
require(
    classifier,
    'server !in CLOUDFLARE_SERVERS',
    'id=\\"challenge-error-title\\"',
    'id=\\"challenge-error-text\\"',
    'mitigatedHeader?.equals("challenge", ignoreCase = true)',
)
forbid(
    classifier,
    'strongChallengeMarker',
    'body.contains("challenge-platform")',
    'body.contains("cf-chl-")',
    'body.contains("just a moment")',
)

browser = 'apps/app/lib/source_browser.dart'
require(
    browser,
    '_verificationBrowserAttempts',
    '_verificationAttemptKey(',
    '_verificationBrowserAttempts.add(automaticVerificationKey)',
    'automatic: true',
    '_verificationBrowserAttempts.add(',
    '_verificationAttemptKey(source, verificationUri)',
    "'verification-auto-loop-guarded'",
    '后续刷新不会反复跳 WebView',
)

require(
    'apps/app/test/source_browser_test.dart',
    'A later ordinary retry must not automatically',
    'expect(webViewOpens, 1);',
    'expect(webViewOpens, 2);',
)

require(
    'apps/app/lib/comic_details.dart',
    '({Uri? verificationUri}) => _recoverSourceAccess(',
    'verificationUri ?? failure.verificationUri',
)

require(
    'tool/test_cloudflare_classifier_kotlin_compile.py',
    'challenge script is not an interactive captcha',
    'Mihon challenge title',
)
require('tool/check.sh', 'test_dev153_mihon_cloudflare_browser_completion_loop_guard.py')
print('dev.153 Mihon Cloudflare browser completion/loop guard: OK')

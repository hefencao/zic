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


activity = read('packages/network_bridge/android/src/main/kotlin/dev/zic/network/NetworkBrowserActivity.kt')
for token in (
    'override fun onPageStarted',
    'navigationGeneration += 1',
    'scheduleVerificationProbe(',
    'expectedGeneration != navigationGeneration',
    'view.progress < 100',
    'challengeFreeSinceUptimeMillis',
    'VERIFICATION_INITIAL_SETTLE_MILLIS = 1500L',
    'VERIFICATION_PROBE_INTERVAL_MILLIS = 500L',
    'VERIFICATION_CLEAR_STABLE_MILLIS = 3000L',
    'CLOUDFLARE_BROWSER_STATE_PROBE',
    "'#challenge-running'",
    "'#cf-challenge-running'",
    "'#challenge-form'",
    "'.cf-turnstile'",
    "'[id^=\\\"cf-chl-\\\"]'",
    "'input[name=\\\"cf-turnstile-response\\\"]'",
    "'iframe[src*=\\\"challenges.cloudflare.com\\\"]'",
    "title.indexOf('just a moment')>=0",
    "body.indexOf('verify you are human')>=0",
    'verificationHandler.removeCallbacksAndMessages(null)',
):
    require(activity, token, 'stable Cloudflare browser completion')

for token in (
    'verificationPageResolved = !challengeVisible',
    'CLOUDFLARE_CHALLENGE_PROBE',
):
    forbid(activity, token, 'single onPageFinished completion')

adr = read('docs/adr/0139-cloudflare-browser-stable-completion.md')
for token in (
    '**状态：Accepted**',
    '连续稳定',
    'Turnstile',
    'onPageFinished',
):
    require(adr, token, 'ADR 0139')

require(read('tool/check.sh'), 'test_dev154_cloudflare_browser_stable_completion.py', 'check integration')
print('dev.154 Cloudflare browser stable completion: OK')

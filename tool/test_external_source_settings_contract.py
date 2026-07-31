#!/usr/bin/env python3
"""Guard the Venera settings/login presentation contract without Flutter SDK."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCREEN = ROOT / "apps/app/lib/external_source_settings_screen.dart"
BROWSER = ROOT / "apps/app/lib/source_browser.dart"

screen = SCREEN.read_text(encoding="utf-8")
browser = BROWSER.read_text(encoding="utf-8")

required_screen = (
    "settings = await _source.loadSettings();",
    "account = await (widget.source as AuthenticatableComicSource)",
    "firstError ??= error;",
    "_loginCredentials()",
    "_loginCookies(account.cookieFields)",
    "_openWebLogin()",
    "_accountSource.logout",
    "snapshot?.localStorage",
)
missing = [token for token in required_screen if token not in screen]
if missing:
    raise SystemExit(f"external source settings contract missing: {missing}")

# Account loading must not be inside the same try that owns settings loading;
# a broken settings callback must not hide every login option.
settings_try = screen.index("settings = await _source.loadSettings();")
settings_catch = screen.index("} on Object catch (error) {", settings_try)
account_try = screen.index("account = await (widget.source", settings_catch)
if not settings_try < settings_catch < account_try:
    raise SystemExit("Venera account loading is still coupled to settings failure")

required_browser = (
    "source.sourceId.startsWith('venera:')",
    "controller.readExternalLoginSnapshot(url)",
    "localStorage: snapshot.localStorage",
    "tooltip: '插件设置与登录'",
)
missing = [token for token in required_browser if token not in browser]
if missing:
    raise SystemExit(f"source browser login entry missing: {missing}")

print("External source settings/login contract: OK")

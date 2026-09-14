#!/usr/bin/env python3
"""Prepare a real Android device for a ZIC Reader validation run.

This is deliberately a preflight only. It installs one explicit Flutter build
mode, cold-starts the app, waits for authoritative Home service adoption, and
verifies that the Reader test target is available on the real app display.
It never taps the Reader entry itself.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "dev.zic.zic"
ACTIVITY = f"{PACKAGE}/.MainActivity"
READY_MARKERS = (
    "durable-services-ready",
)
AUTHORITATIVE_HANDOFF_MARKERS = (
    "services-handoff-complete mode=authoritative-reload",
    "services-handoff-complete mode=revision-fast-path",
)
DEFAULT_TIMEOUT_SECONDS = {
    "profile": 20.0,
    "release": 20.0,
    "debug": 60.0,
}


def run_adb(*args: str, timeout: float = 20.0) -> str:
    completed = subprocess.run(
        ["adb", *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise RuntimeError(f"adb {' '.join(args)} failed: {detail}")
    return completed.stdout


def normalize_abi(abi: str) -> str:
    value = abi.strip()
    aliases = {
        "arm64-v8a": "arm64-v8a",
        "armeabi-v7a": "armeabi-v7a",
        "x86_64": "x86_64",
    }
    try:
        return aliases[value]
    except KeyError as error:
        raise ValueError(f"unsupported Android ABI for split APK: {value!r}") from error


def apk_path(mode: str, abi: str) -> Path:
    normalized = normalize_abi(abi)
    return (
        ROOT
        / "apps/app/build/app/outputs/flutter-apk"
        / f"app-{normalized}-{mode}.apk"
    )


def readiness_markers_present(log_text: str) -> bool:
    return all(marker in log_text for marker in READY_MARKERS) and any(
        marker in log_text for marker in AUTHORITATIVE_HANDOFF_MARKERS
    )


def input_command(display: int, *input_args: str) -> list[str]:
    return ["adb", "shell", "input", "-d", str(display), *input_args]


def activity_display(dumpsys: str) -> int | None:
    display: int | None = None
    for line in dumpsys.splitlines():
        match = re.match(r"Display #(\d+) \(activities from top to bottom\):", line)
        if match is not None:
            display = int(match.group(1))
            continue
        if display is not None and PACKAGE in line and ".MainActivity" in line:
            return display
    return None


def wait_for_readiness(timeout_seconds: float) -> tuple[str, float]:
    deadline = time.monotonic() + timeout_seconds
    started = time.monotonic()
    latest = ""
    while time.monotonic() < deadline:
        latest = run_adb("logcat", "-d", "-v", "brief", timeout=10.0)
        if readiness_markers_present(latest):
            return latest, time.monotonic() - started
        time.sleep(0.20)
    missing = [marker for marker in READY_MARKERS if marker not in latest]
    if not any(marker in latest for marker in AUTHORITATIVE_HANDOFF_MARKERS):
        missing.append(
            "services-handoff-complete mode=<authoritative-reload|revision-fast-path>"
        )
    raise TimeoutError(
        "Reader preflight timed out before authoritative Home readiness; "
        f"missing={missing} timeout={timeout_seconds:.1f}s"
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--mode",
        choices=("debug", "profile", "release"),
        default="profile",
        help="exact Flutter build mode to install; profile is canonical for performance",
    )
    parser.add_argument(
        "--display",
        type=int,
        default=0,
        help="expected physical app display for subsequent adb input (default: 0)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=None,
        help="readiness upper bound in seconds; readiness is still event-gated",
    )
    parser.add_argument(
        "--no-install",
        action="store_true",
        help="reuse the currently installed app; intended only for an already-proven build",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    devices = run_adb("devices")
    attached = [
        line for line in devices.splitlines()[1:] if line.strip().endswith("\tdevice")
    ]
    if len(attached) != 1:
        raise RuntimeError(
            "Reader preflight requires exactly one ready adb device; "
            f"found={len(attached)}"
        )

    abi = normalize_abi(run_adb("shell", "getprop", "ro.product.cpu.abi"))
    selected_apk = apk_path(args.mode, abi)
    if not args.no_install:
        if not selected_apk.is_file():
            raise FileNotFoundError(
                f"missing {args.mode} split APK for {abi}: {selected_apk}; "
                f"build it with ./tool/build_android.sh {args.mode}"
            )
        print(f"install mode={args.mode} abi={abi} apk={selected_apk}")
        run_adb("install", "-r", str(selected_apk), timeout=120.0)
    else:
        print(f"reuse-installed mode-claim={args.mode} abi={abi}")

    run_adb("shell", "am", "force-stop", PACKAGE)
    run_adb("logcat", "-c")
    launch = run_adb("shell", "am", "start", "-W", "-n", ACTIVITY)
    if "Status: ok" not in launch:
        raise RuntimeError(f"ZIC cold start did not report success:\n{launch}")

    timeout_seconds = (
        args.timeout
        if args.timeout is not None
        else DEFAULT_TIMEOUT_SECONDS[args.mode]
    )
    if timeout_seconds <= 0:
        raise ValueError("--timeout must be positive")
    _, ready_seconds = wait_for_readiness(timeout_seconds)

    activities = run_adb("shell", "dumpsys", "activity", "activities")
    actual_display = activity_display(activities)
    if actual_display is None:
        raise RuntimeError("ZIC MainActivity is not present in activity display state")
    if actual_display != args.display:
        raise RuntimeError(
            "ZIC MainActivity is on an unexpected display; "
            f"expected={args.display} actual={actual_display}. "
            "Do not inject input until the display target is resolved."
        )

    hierarchy = run_adb("exec-out", "uiautomator", "dump", "/dev/tty", timeout=20.0)
    if 'content-desc="阅读历史"' not in hierarchy:
        raise RuntimeError(
            "authoritative Home is ready but the reading-history section is not "
            "present in the current accessibility tree"
        )

    print(
        "READY "
        f"mode={args.mode} abi={abi} display={actual_display} "
        f"authoritativeHomeSeconds={ready_seconds:.3f}"
    )
    print(
        "subsequent-input-prefix="
        f"adb shell input -d {actual_display} <tap|swipe|keyevent> ..."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (FileNotFoundError, RuntimeError, TimeoutError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)

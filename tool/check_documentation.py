#!/usr/bin/env python3
"""Keep stable documentation separate from iteration evidence and history."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

LIMITS = {
    "README.md": 180,
    "docs/ARCHITECTURE.md": 420,
    "docs/SPEC.md": 300,
    "docs/IMPLEMENTATION_PLAN.md": 180,
    "docs/IMPLEMENTATION_STATUS.md": 220,
    "docs/NEXT_CHAT_HANDOFF.md": 80,
}

for relative, limit in LIMITS.items():
    path = ROOT / relative
    if not path.is_file():
        raise SystemExit(f"FAIL: missing documentation file: {relative}")
    lines = path.read_text(encoding="utf-8").splitlines()
    if len(lines) > limit:
        raise SystemExit(
            f"FAIL: {relative} has {len(lines)} lines; responsibility limit is {limit}"
        )

stable = {
    relative: (ROOT / relative).read_text(encoding="utf-8")
    for relative in (
        "README.md",
        "docs/ARCHITECTURE.md",
        "docs/SPEC.md",
        "docs/IMPLEMENTATION_PLAN.md",
        "docs/IMPLEMENTATION_STATUS.md",
    )
}
version_heading = re.compile(r"^#{1,6}\s+.*(?:dev\.\d+|0\.\d+\.\d+-dev\.)", re.I | re.M)
for relative, text in stable.items():
    if version_heading.search(text):
        raise SystemExit(f"FAIL: version history leaked into {relative}")

readme = stable["README.md"]
for token in ("严格以 dev.", "本轮修复", "设备 Trace 显示", "当前环境仍"):
    if token in readme:
        raise SystemExit(f"FAIL: release/audit prose leaked into README: {token}")

architecture = stable["docs/ARCHITECTURE.md"]
for token in ("条事件", "p50", "p95", "当前环境", "已通过测试", "验证结果"):
    if token in architecture:
        raise SystemExit(f"FAIL: audit/status claim leaked into Architecture: {token}")

spec = stable["docs/SPEC.md"]
for token in ("当前环境", "已完成", "已通过", "本轮"):
    if token in spec:
        raise SystemExit(f"FAIL: implementation claim leaked into Spec: {token}")

plan = stable["docs/IMPLEMENTATION_PLAN.md"]
if len(re.findall(r"已完成|completed|previous iteration", plan, re.I)) > 1:
    raise SystemExit("FAIL: completed history leaked into Implementation Plan")

status = stable["docs/IMPLEMENTATION_STATUS.md"]
for token in (
    "Implemented",
    "Verified-static",
    "Verified-toolchain",
    "Verified-device",
    "Unverified",
):
    if token not in status:
        raise SystemExit(f"FAIL: Status lacks verification level: {token}")

policy = (ROOT / "docs/DOCUMENTATION_POLICY.md").read_text(encoding="utf-8")
for token in (
    "README",
    "ARCHITECTURE",
    "SPEC",
    "IMPLEMENTATION_PLAN",
    "IMPLEMENTATION_STATUS",
    "docs/audits",
    "未经验证的推断",
):
    if token not in policy:
        raise SystemExit(f"FAIL: documentation policy missing: {token}")

app_pubspec = (ROOT / "apps/app/pubspec.yaml").read_text(encoding="utf-8")
match = re.search(r"^version:\s*0\.31\.0\+(\d+)$", app_pubspec, re.M)
if match is None:
    raise SystemExit("FAIL: cannot read App build number")
build = match.group(1)
if f"0.31.0-dev.{build}" not in status or f"0.31.0+{build}" not in status:
    raise SystemExit("FAIL: Status version does not match App pubspec")
handoff = (ROOT / "docs/NEXT_CHAT_HANDOFF.md").read_text(encoding="utf-8")
if f"dev.{build}" not in handoff:
    raise SystemExit("FAIL: Handoff baseline does not match App build")

print("documentation responsibilities: OK")

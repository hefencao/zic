#!/usr/bin/env python3
"""Keep stable documentation separate from iteration evidence and history."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

LIMITS = {
    "README.md": 180,
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

MAX_LINE_LENGTHS = {
    "docs/IMPLEMENTATION_STATUS.md": 250,
    "docs/NEXT_CHAT_HANDOFF.md": 250,
}
for relative, max_len in MAX_LINE_LENGTHS.items():
    path = ROOT / relative
    if not path.is_file():
        continue
    for line_num, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if len(line) > max_len:
            raise SystemExit(
                f"FAIL: {relative}:{line_num} exceeds max line length ({len(line)} > {max_len})"
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
    "IMPLEMENTATION_STATE.json",
    "docs/archive/adr",
    "docs/archive/audits",
    "未经验证的推断",
):
    if token not in policy:
        raise SystemExit(f"FAIL: documentation policy missing: {token}")

for retired_path in ("docs/adr", "docs/audits"):
    if (ROOT / retired_path).exists():
        raise SystemExit(f"FAIL: historical documentation must stay archived: {retired_path}")

details_start = architecture.index("### 详情页与来源迁移组合")
details_end = architecture.index("### 插件与平台桥", details_start)
details_architecture = architecture[details_start:details_end]
if "章节目录直接以 `SliverList`" not in details_architecture:
    raise SystemExit("FAIL: chapter viewport contract belongs in details architecture")
home_start = architecture.index("### Home 组合与生命周期")
if "章节目录直接以 `SliverList`" in architecture[home_start:details_start]:
    raise SystemExit("FAIL: details layout leaked into Home composition architecture")

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

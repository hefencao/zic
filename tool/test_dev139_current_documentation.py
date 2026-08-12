#!/usr/bin/env python3
"""Keep stable documentation aligned with current production code."""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} missing current-code documentation token: {token}")


profile = read("packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart")
role_window = read("packages/pipeline/lib/src/role_window.dart")
policy = read("packages/pipeline/lib/src/heuristic_policy.dart")
refill = read("packages/sessions/lib/src/decode_refill_policy.dart")
session = read("packages/pipeline_runtime/lib/src/pipeline_reader_session.dart")
download_job = read("packages/sessions/lib/src/download_job.dart")
prefix = read("packages/sessions/lib/src/webp_decode_prefix_hints.dart")
artifact_cache = read("packages/downloads/lib/src/artifact_cache_manager.dart")
texture = read(
    "packages/texture_bridge/android/src/main/kotlin/dev/zic/texture/TextureBridgePlugin.kt"
)
architecture = read("docs/ARCHITECTURE.md")
spec = read("docs/SPEC.md")
status = read("docs/IMPLEMENTATION_STATUS.md")
handoff = read("docs/NEXT_CHAT_HANDOFF.md")
agents = read("AGENTS.md")

# Production constants that the documents summarize.
for token in (
    "forwardEncodedPages: 7",
    "backwardEncodedPages: 3",
    "forwardDecodePages: 2",
    "backwardDecodePages: 1",
    "networkConcurrency: 5",
    "localSourceConcurrency: 2",
    "remoteSourceConcurrency: 5",
    "decodeConcurrency: 3",
    "uploadConcurrency: 2",
):
    require(profile, token, "ReaderPipelineProfile")
for token in (
    "this.transitionThreshold = 0.15",
    "PageRole.transition",
    "PageRole.last",
):
    require(role_window, token, "RoleResolver")
for token in (
    "PageRole.current => 7",
    "PageRole.transition => 5",
    "PageRole.next2 => decodeWarmPages ? 3 : 0",
    "PageRole.previous => decodeWarmPages ? 2 : 0",
):
    require(policy, token, "HeuristicPolicy")
for token in (
    "stage: 't>0'",
    "_RefillStep(_WaterlineRole.current, 2, 'c>2')",
    "_RefillStep(_WaterlineRole.next, 4, 'n>4')",
):
    require(refill, token, "StagedDecodeRefillPolicy")
for token in (
    "Duration(minutes: 2)",
    "_maxRetainedReaderSessions = 1",
    "reservedHighPrioritySlots: 1",
    "highPriorityThreshold: 1000",
    "preemptionThreshold: 40",
):
    require(session, token, "PipelineReaderSessionFactory")
for token in ("var flushTarget = 16 * 1024", "sourceProgressQuantumBytes"):
    require(download_job, token, "DownloadJob")
for token in (
    "localWebpDecodePrefixQuantumBytes = 1024 * 1024",
    "remoteWebpDecodePrefixQuantumBytes = 256 * 1024",
):
    require(prefix, token, "WebpDecodePrefixHints")
for token in ("memoryMaxEntries = 10", "memoryMaxBytes = 256 * 1024 * 1024"):
    require(artifact_cache, token, "ArtifactCacheManager")
for token in ("BLIT_LANE_COUNT = 1", "mainHandler.post"):
    require(texture, token, "TextureBridgePlugin")

# Stable docs must distinguish the currently separate policy layers.
for token in (
    "前 7、后 3",
    "前 2、后 1",
    "7 / 5 / 3 / 2",
    "t>0",
    "首批约 16 KiB",
    "remote prefix quantum：256 KiB",
    "最多保留 1 个 idle 章节会话",
    "TTL 为 2 分钟",
    "默认热字节 10 项/256 MiB",
    "一个串行 blit lane",
    "NetLane",
):
    require(architecture, token, "Architecture")
pubspec_for_spec = read("apps/app/pubspec.yaml")
spec_version = re.search(r"^version:\s*0\.31\.0\+(\d+)$", pubspec_for_spec, re.M)
spec_build = int(spec_version.group(1)) if spec_version is not None else 0
spec_window_token = (
    "encoded逻辑/retention window：前 7 / 后 3"
    if spec_build >= 247
    else "encoded download window：前 7 / 后 3"
)
for token in (
    spec_window_token,
    "动态 holder 最大水位为 current/next/next2/previous：7 / 5 / 3 / 2",
    "current 浅水位 bootstrap MUST 优先",
    "NetLane` MUST 是页面网络的唯一调度权威",
    "一个 idle 章节会话最多两分钟",
):
    require(spec, token, "Spec")
if spec_build >= 247:
    require(spec, "network下界previous2/next4", "Spec")

for forbidden in (
    "DownloadFlowGate",
    "downloadFlowPressure",
    "sched_setaffinity",
    "4 ms `Timer.periodic`",
    "startup-buffer 状态",
):
    if forbidden in architecture or forbidden in spec:
        raise SystemExit(f"superseded implementation leaked into stable docs: {forbidden}")

# AGENTS must make current-code documentation part of the change contract.
for token in (
    "Stable documentation must describe current production code",
    "NetLane` is the only network scheduling authority",
    "ADR status must be exactly",
):
    require(agents, token, "AGENTS")

# Recent ADR status values are exact and the consolidation ADR is current.
allowed = {"Proposed", "Provisional", "Accepted", "Superseded", "Rejected"}
for number in range(113, 123):
    matches = sorted((ROOT / "docs/adr").glob(f"{number:04d}-*.md"))
    if not matches:
        continue
    text = matches[0].read_text(encoding="utf-8")
    match = re.search(r"^\*\*状态：([^*]+)\*\*$", text, re.M)
    if match is None or match.group(1).strip() not in allowed:
        raise SystemExit(f"ADR {number:04d} has a non-canonical status")
require(read("docs/adr/0122-current-reader-pipeline-authority-consolidation.md"),
        "**状态：Accepted**", "ADR 0122")

pubspec = read("apps/app/pubspec.yaml")
version = re.search(r"^version:\s*0\.31\.0\+(\d+)$", pubspec, re.M)
if version is None or int(version.group(1)) < 139:
    raise SystemExit("dev.139 documentation gate requires App build >= 139")
build = version.group(1)
if f"0.31.0-dev.{build}" not in status or f"0.31.0+{build}" not in status:
    raise SystemExit("Implementation Status does not match App build")
if f"dev.{build}" not in handoff:
    raise SystemExit("Handoff does not match App build")

print("dev.139 current-code documentation consistency: OK")

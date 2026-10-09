#!/usr/bin/env python3
"""Keep stable documentation aligned with current production code."""
from __future__ import annotations

import json
import re
from collections import Counter
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
    "this.transitionThreshold = defaultTransitionCoverageThreshold",
    "PageRole.transition",
    "PageRole.last",
):
    require(role_window, token, "RoleResolver")
require(
    read("packages/pipeline/lib/src/coverage_thresholds.dart"),
    "const double defaultTransitionCoverageThreshold = 0.15;",
    "RoleResolver threshold authority",
)
for token in (
    "PageRole.current => 7",
    "PageRole.transition => 5",
    "PageRole.next2 => decodeWarmPages ? 3 : 0",
    "PageRole.previous => decodeWarmPages ? 2 : 0",
):
    require(policy, token, "HeuristicPolicy")
for token in (
    "stage: DecodeWaterlineStage.transitionFirstFrame",
    "DecodeWaterlineStage.currentBootstrap",
    "DecodeWaterlineStage.nextMax",
):
    require(refill, token, "StagedDecodeRefillPolicy")
for token in (
    "Duration(minutes: 2)",
    "_maxRetainedReaderSessions = 2",
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
    "idle LRU 最多保留最近两个 exact session key",
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
    "encoded逻辑/retention与network-demand window：前 7 / 后 3"
    if spec_build >= 249
    else "encoded逻辑/retention window：前 7 / 后 3"
    if spec_build >= 247
    else "encoded download window：前 7 / 后 3"
)
for token in (
    spec_window_token,
    "动态 holder 最大水位为 current/next/next2/previous：7 / 5 / 3 / 2",
    "current 浅水位 bootstrap MUST 优先",
    "NetLane` MUST 是页面网络的唯一调度权威",
    "LRU最多2个exact session",
    "已取消任务真实退出后 MUST成为media-empty shell",
):
    require(spec, token, "Spec")
if spec_build >= 271:
    require(spec, "encoded逻辑/retention与network-demand window：前 7 / 后 3", "Spec")
    require(spec, "body-read permit", "Spec")
    require(spec, "transport lease", "Spec")
    require(spec, "inactive-transport-lease-reclaim", "Spec")
    require(spec, "ArtifactCacheReadScheduler", "Spec")
elif spec_build >= 269:
    require(spec, "encoded逻辑/retention与network-demand window：前 7 / 后 3", "Spec")
    require(spec, "body-read permit", "Spec")
    require(spec, "inactive-response-retention-eviction", "Spec")
    require(spec, "ArtifactCacheReadScheduler", "Spec")
elif spec_build >= 268:
    require(spec, "encoded逻辑/retention与network-demand window：前 7 / 后 3", "Spec")
    require(spec, "body-read permit", "Spec")
    require(spec, "parked-response-eviction", "Spec")
elif spec_build >= 249:
    require(spec, "encoded逻辑/retention与network-demand window：前 7 / 后 3", "Spec")
    require(spec, "streamBackpressure", "Spec")
elif spec_build >= 248:
    require(spec, "previous2/next4作为最低预下载资格窗口", "Spec")
    require(spec, "speculative byte budget MUST由NetLane约束同时active的动画encoded工作", "Spec")
elif spec_build >= 247:
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
    matches = sorted((ROOT / "docs/archive/adr").glob(f"{number:04d}-*.md"))
    if not matches:
        continue
    text = matches[0].read_text(encoding="utf-8")
    match = re.search(r"^\*\*状态：([^*]+)\*\*$", text, re.M)
    if match is None or match.group(1).strip() not in allowed:
        raise SystemExit(f"ADR {number:04d} has a non-canonical status")
require(read("docs/archive/adr/0122-current-reader-pipeline-authority-consolidation.md"),
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

# Historical requirements must not become a repair backlog for retired owners.
governance_path = "docs/IMPLEMENTATION_STATE.json"
governance = json.loads(read(governance_path))
governance_source = read(governance_path)
if len(governance_source.encode("utf-8")) > 96 * 1024 or len(governance_source.splitlines()) > 400:
    raise SystemExit("current governance must remain a bounded current projection")
if "supplemental_acceptance" in governance or "historical_requirement_summary" in governance:
    raise SystemExit("historical governance objects belong only in the archive")
archived_path = governance["historical_record"]
if not archived_path.startswith("docs/archive/audits/"):
    raise SystemExit("current governance must reference the archived history")
archived_governance = json.loads(read(archived_path))
requirements = governance["requirements"]
if len(requirements) != 112 or len({row["id"] for row in requirements}) != 112:
    raise SystemExit("current governance must retain all 112 requirement IDs")
if any(not row.get("current_contract", "").strip() for row in requirements):
    raise SystemExit("every governance requirement needs an explicit current contract")
if dict(Counter(row["status"] for row in requirements)) != governance["requirement_summary"]:
    raise SystemExit("current governance status counts are stale")
historical_requirements = archived_governance["requirements"]
if {row["id"] for row in requirements} != {row["id"] for row in historical_requirements}:
    raise SystemExit("current governance lost archived requirement IDs")
if dict(Counter(row["historical_status"] for row in historical_requirements)) != archived_governance["historical_requirement_summary"]:
    raise SystemExit("historical governance status counts are stale")
for row in requirements:
    if set(row) - {"id", "status", "current_contract", "remaining_acceptance", "evidence_reproducibility"}:
        raise SystemExit(f"{row['id']} accumulates historical governance fields")
    if row["status"] not in {"pending", "partial", "verified_device", "verified_toolchain", "superseded"}:
        raise SystemExit(f"{row['id']} has an unknown acceptance status")
    if row["status"] == "partial" and not row.get("remaining_acceptance"):
        raise SystemExit(f"{row['id']} hides remaining acceptance")
    if row["status"] == "pending" and "remaining_acceptance" in row and not row["remaining_acceptance"]:
        raise SystemExit(f"{row['id']} hides pending acceptance")
completed_plan_markers = {
    "SWG-PLAN-039": "普通主入口用来源实际确认的同源successor验证Home版本更新筛选",
    "SWG-PLAN-049": "继续验其它transport/partial动画、真实origin/其它Mihon客户端与teardown",
    "SWG-PLAN-041": "http://img*.wnimg*.ru/...",
    "SWG-PLAN-070": "已激活插件连续执行 WebView验证、设置修改和同包更新",
    "SWG-PLAN-072": "记录真实插件重启后Cookie snapshot reset与首个request时序",
    "SWG-PLAN-052": "冷启动直接激活 `venera:ehentai`",
    "SWG-PLAN-008": "证明exact+verified-equivalent miss不materialize durable-store",
    "SWG-PLAN-009": "009选定可播放/0已解码帧的同response停驻恢复保持",
    "SWG-PLAN-012": "继续Range probe/full-body catch-up的EOF/mismatch",
    "SWG-PLAN-029": "Mihon/source筛选以真实 `getFilterList()` 为唯一 schema owner",
    "SWG-PLAN-101": "已有partial动画重入必须从frame0立即播放",
    "SWG-PLAN-053": "继续对 `home-history:<canonical identity>` 对齐 source/cache/decode trace",
    "SWG-PLAN-092": "若 current 仍断粮，只在 NetLane ranking",
    "SWG-PLAN-103": "103当前8源选定分页保持",
    "SWG-PLAN-073": "对无法识别的 APK导出 package、metadata key、ABI和 entry class诊断",
    "SWG-PLAN-027": "对同一漫画执行“漫画源列表首帧 → 打开详情 → 返回列表",
    "SWG-PLAN-021": "Venera current pressure经requestId取消现有isolated Dart rhttp请求",
    "SWG-PLAN-048": "048的全仓入口/所有权门禁与既有cache/gateway fixtures保持",
    "SWG-PLAN-062": "在同一 Mihon漫画真实raw alias或标题/简介/thumbnail/memo变化后",
    "SWG-PLAN-011": "后续真机验证chapter B与Reader A共享physical transfer",
    "SWG-PLAN-098": "dev.228后真机验证改为直接统计",
    "SWG-PLAN-028": "记录 `source-cover:<sourceId>\\0<canonicalComicId>`",
    "SWG-PLAN-046": "在设置中切换自定义 User-Agent后分别验证通用 HTTP",
    "SWG-PLAN-047": "对 Mihon/Venera source记录 host replay / source-owned fallback原因",
    "SWG-PLAN-081": "验证打开浏览器后立即取消/Activity中断不会擦除",
    "SWG-PLAN-063": "在source暂不可用时补真机`mihon:resource:` durable封面命中",
    "SWG-PLAN-066": "在插件runtime激活失败时重启App，验证durable封面命中",
    "SWG-PLAN-082": "让同一漫画同时进入更新、书架和历史，并改变 raw Mihon alias",
    "SWG-PLAN-091": "对比raw transport chunk、DownloadJob首批16KiB/后续64KiB聚合",
    "SWG-PLAN-018": "同时复测短时N→N+1→N与跨session跳页",
    "SWG-PLAN-093": "真机连续快速前后翻页验证 VibeVenera retained-receiving语义",
}
plan = read("docs/IMPLEMENTATION_PLAN.md")
for row in requirements:
    marker = completed_plan_markers.get(row["id"])
    if marker and row["status"] in {"verified_device", "verified_toolchain", "superseded"} and marker in plan:
        raise SystemExit(f"{row['id']} leaves completed acceptance in the active Plan")
rejected = archived_governance["supplemental_acceptance"]["mihon-locator-fused-decoding-2026-10-05"]
for path in (
    "docs/archive/audits/reader_media_runtime_state_audit.json",
    "docs/archive/audits/download_system_state_audit.json",
    "docs/archive/audits/user-repeated-download-loading-regressions-2026-10-03.json",
):
    parent = json.loads(read(path))
    if parent["current_requirement_state"] != governance_path + "#requirements":
        raise SystemExit(f"{path} does not reference current governance")
    attribution = parent.get("current_reader_remaining_GC_attribution", {})
    if rejected["status"].startswith("candidate_rejected") and "Evaluate fused" in attribution.get("next_action", ""):
        raise SystemExit(f"{path} reopens a rejected allocation candidate")

print("dev.139 current-code documentation consistency: OK")

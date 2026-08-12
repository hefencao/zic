#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")

def require(cond: bool, message: str) -> None:
    if not cond:
        raise SystemExit(f"FAIL: {message}")

pubspec = read("apps/app/pubspec.yaml")
props = read("apps/app/android/zic-version.properties")
net = read("packages/sessions/lib/src/net_lane.dart")
owner = read("packages/sessions/lib/src/download_transfer_owner.dart")
rank_policy = read("packages/sessions/lib/src/transfer_rank_policy.dart")
owner_test = read("packages/sessions/test/download_transfer_owner_test.dart")
net_test = read("packages/sessions/test/net_lane_test.dart")
rank_test = read("packages/sessions/test/transfer_rank_policy_test.dart")
spec = read("docs/SPEC.md")
architecture = read("docs/ARCHITECTURE.md")
check = read("tool/check.sh")

m = re.search(r"^version:\s*0\.31\.0\+(\d+)\s*$", pubspec, re.M)
require(m is not None and int(m.group(1)) >= 241, "App build must be >=241")
m2 = re.search(r"^versionCode=(\d+)\s*$", props, re.M)
require(m2 is not None and int(m2.group(1)) == int(m.group(1)), "Android versionCode must match App build")

require("final class NetPolicyRank" in net, "NetLane must own effective network policy rank")
require("NetPolicyRank? activePolicyRank(" in net, "NetLane must expose active rank projection")
require("bool incomingOutranks(" in net, "NetLane must own the rank-margin comparison")
require("_policyRank(task, basePriority: task.priority)" in net, "ordinary victim preemption must use the same policy rank")
require("net.activePolicyRank(" in owner and "net.incomingOutranks(" in owner, "provider takeover must reuse NetLane rank")
require("activeClaim?.demand.priority ?? lease.admittedPriority" in owner, "live/orphan provider state must only choose incumbent base rank")
require("if (providerOrphaned)" not in owner, "provider scheduling must not branch on orphan taxonomy")
require("net.isHighPriority" not in owner, "provider scheduling must not branch on high-priority class")
require("preferred.demand.priority > activeClaim.demand.priority" not in owner, "provider scheduling must not carry a strict-higher duplicate policy")
require("lease.exactId == preferred.exactId" in owner, "same exact request authority remains a no-op identity invariant")
require("'takeoverClass': 'policy-rank'" in owner and "'fromEffectiveRank'" in owner and "'rankMargin'" in owner, "rank inputs/results must be trace-visible")

require("final class TransferRankPolicy" in rank_policy, "cost admission rank policy must be explicit")
require("fullBodyCatchupCostRank" in rank_policy and "demandRank" in rank_policy, "full-body admission must compare demand rank with cost rank")
require("rankPolicy.allowsFullBodyCatchup(" in owner, "DownloadTransferOwner must delegate costly catchup admission")
for stale in ("foregroundAdjacentPriorityFloor", "visibleTransitionPriorityFloor", "const largePrefixBytes", "const veryLargePrefixBytes"):
    require(stale not in owner, f"scattered catchup policy must be removed: {stale}")

require("provider handoff follows NetLane rank margin instead of situation branches" in owner_test, "provider behavior rank regression is required")
require("_desired(exact, priority: 850)" in owner_test and "_desired(exact, priority: 860)" in owner_test, "provider behavior test must prove preemption margin, not role taxonomy")
require("provider decisions reuse the scheduler restart-cost policy rank" in net_test, "NetLane rank projection regression is required")
require("lane.incomingOutranks(900, invested), isFalse" in net_test and "lane.incomingOutranks(1000, invested), isTrue" in net_test, "restart cost and current must be parameters of the same rank")
require("full-body catchup is one demand-rank versus cost-rank comparison" in rank_test, "catchup rank regression is required")

require("policy rank" in architecture, "Architecture must describe unified policy rank ownership")
require("policy rank" in spec, "SPEC must describe unified policy rank contract")
for path in (
    "docs/adr/0221-unified-transfer-policy-rank.md",
    "docs/audits/dev241-policy-rank-consolidation-audit.md",
):
    require((ROOT / path).is_file(), f"missing governance file: {path}")
require("test_dev241_unified_transfer_policy_rank.py" in check, "release gate wiring")

print("PASS: dev.241 unified transfer policy rank")

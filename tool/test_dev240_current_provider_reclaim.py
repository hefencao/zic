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
owner_test = read("packages/sessions/test/download_transfer_owner_test.dart")
spec = read("docs/SPEC.md")
architecture = read("docs/ARCHITECTURE.md")

m = re.search(r"^version:\s*0\.31\.0\+(\d+)\s*$", pubspec, re.M)
require(m is not None and int(m.group(1)) >= 240, "App build must be >=240")
m2 = re.search(r"^versionCode=(\d+)\s*$", props, re.M)
require(m2 is not None and int(m2.group(1)) == int(m.group(1)), "Android versionCode must match App build")

require("bool isHighPriority(int priority) => priority >= _core.highPriorityThreshold;" in net,
        "NetLane must own the high-priority classification")
require("final retainedSameExact = lease.transportRetainedBeyondConsumer" in owner,
        "same-exact retained provider reuse must be explicit")
require("lease.exactId == preferred.exactId" in owner and "if (retainedSameExact) return false;" in owner,
        "same-exact retained provider must not churn")
require("if (providerOrphaned) {" in owner and "net.isHighPriority(preferred.demand.priority)" in owner,
        "orphaned different-exact provider must be reclaimable only by scheduler high-priority demand")
require("preferred.demand.priority > activeClaim.demand.priority" in owner,
        "live provider handoff must remain strict-higher priority")
require("'high-priority-orphan-reclaim'" in owner and "'strict-live-priority'" in owner,
        "provider takeover class must be trace-visible")
require("priority == 1000" not in owner and "priority==1000" not in owner,
        "sessions must not hard-code Reader current priority")

require("orphaned provider claim stays on the admitted task until provider disposal" in owner_test,
        "ordinary orphan retention regression must remain")
require("_desired(exact, priority: 820)" in owner_test,
        "ordinary lower-priority orphan must remain retained")
require("current exact demand reclaims an orphaned retained provider without replacing the physical partial" in owner_test,
        "current orphan-provider reclaim behavior regression is required")
require("await retainedOldTransport.cancelled.future;" in owner_test and "await currentTransport.opened.future;" in owner_test,
        "current reclaim test must prove old attempt cancellation and preferred provider open")
require("expect(identical(registry.find(exact), session), isTrue);" in owner_test,
        "current provider reclaim must preserve the physical session")
require("expect(session.committedLength, prefixLength);" in owner_test,
        "current provider reclaim must preserve committed partial bytes")
require("expect(session.effectivePriority, 1000);" in owner_test,
        "reclaimed physical task must remain current priority")

require("NetLane high-priority class" in spec,
        "SPEC must assign orphaned current reclaim classification to NetLane")
require("NetLane high-priority class" in architecture,
        "Architecture must assign high-priority provider reclaim to NetLane classification")

for path in (
    "docs/adr/0220-current-high-priority-provider-reclaim.md",
    "docs/audits/dev240-current-provider-reclaim-root-cause-audit.md",
):
    require((ROOT / path).is_file(), f"missing governance file: {path}")

print("PASS: dev.240 current high-priority provider reclaim")

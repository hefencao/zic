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
owner = read("packages/sessions/lib/src/download_transfer_owner.dart")
owner_test = read("packages/sessions/test/download_transfer_owner_test.dart")
spec = read("docs/SPEC.md")
architecture = read("docs/ARCHITECTURE.md")

m = re.search(r"^version:\s*\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)\s*$", pubspec, re.M)
require(m is not None and int(m.group(1)) >= 238, "App build must be >=238")
m2 = re.search(r"^versionCode=(\d+)\s*$", props, re.M)
require(m2 is not None and int(m2.group(1)) == int(m.group(1)), "Android versionCode must match App build")

build = int(m.group(1))
if build >= 244:
    require("providerOrphaned" not in owner, "dev.244+ provider claim taxonomy must not drive admitted task lifetime")
    require("_handoffActiveProviderIfNeeded" not in owner, "dev.244+ must remove logical provider takeover control flow")
    require("activeProviderExactId" in owner, "task-lifetime provider diagnostics must remain available")
elif build >= 241:
    require("final providerOrphaned = activeClaim == null;" in owner, "dev.241-243 provider claim orphaning remains a rank input")
    require("if (providerOrphaned)" not in owner, "dev.241+ must not branch scheduling policy on orphan taxonomy")
    require("lease.exactId == preferred.exactId" in owner, "same-exact request authority must remain a no-op identity invariant")
    require("lease.admittedPriority" in owner and "activeClaim?.demand.priority" in owner, "orphan/live provider state must feed one incumbent rank")
    require("net.activePolicyRank(" in owner and "net.incomingOutranks(" in owner, "provider retention/takeover must be one NetLane rank comparison")
elif build >= 240:
    require("if (providerOrphaned) {" in owner, "dev.240 must branch orphan retention explicitly")
    require("!net.isHighPriority(preferred.demand.priority)" in owner, "ordinary orphaned work must stay retained while high-priority demand may reclaim")
    require("retainedSameExact" in owner, "same-exact retained provider must not churn on Reader generation changes")
    require("preferred.demand.priority > activeClaim.demand.priority" in owner, "dev.240 live provider handoff must remain strict-priority only")
else:
    require("if (providerOrphaned) return false;" in owner, "claim orphaning alone must not revoke an admitted provider task")
    require("preferred.demand.priority > activeClaim.demand.priority" in owner, "live provider handoff must remain strict-priority only")
if build >= 239:
    require("transportRetainedBeyondConsumer" in owner, "dev.239+ must make transport lifetime explicit")
    require("consumer-bound transport" in owner, "dev.239+ must keep the consumer-bound close barrier explicit")
    require("entry.value.transportRetainedBeyondConsumer" in owner, "dev.239+ disposal must exempt only explicit task-retained leases")
else:
    require("Only the provider consumer's real disposal boundary" in owner, "provider transport-owner disposal boundary must be explicit")
    require("providerKeys.add(key);\n      }\n    }\n    // Only the provider consumer's real disposal boundary" in owner, "dispose key collection must not duplicate the cancellation")
require(owner.count("net.cancel(key);") >= 1, "consumer-bound provider disposal must still cancel transport before close")

require("orphaned provider claim stays on the admitted task until provider disposal" in owner_test, "retained orphan provider behavior regression is required")
require("expect(newTransport.opened.isCompleted, isFalse);" in owner_test, "new exact provider must not open merely because the old claim detached")
require("expect(owner.activeProviderScope(physical), 'reader-old-provider');" in owner_test, "admitted provider lease must survive claim orphaning")
require("await oldReader.dispose();" in owner_test and "await newTransport.opened.future;" in owner_test, "real provider disposal must still rebind to the remaining consumer")
require("expect(identical(registry.find(exact), session), isTrue);" in owner_test, "provider disposal handoff must preserve the physical session")
require("expect(session.committedLength, greaterThan(0));" in owner_test, "provider disposal handoff must preserve committed partial bytes")

require("logical provider claim撤销 MUST NOT单独取消" in spec, "SPEC must separate claim and admitted-attempt lifetime")
if build >= 244:
    require("provider exact" in architecture and "task lifetime" in architecture, "Architecture must bind provider request authority to admitted task lifetime")
elif build >= 241:
    require("logical claim lifetime、transport lifetime与request/provider选择彼此分离" in architecture, "Architecture must preserve the claim/transport/provider lifetime split")
else:
    require("claim lifetime不得再冒充transport lifetime" in architecture, "Architecture must name the corrected ownership boundary")

for path in (
    "docs/archive/adr/0218-retained-orphaned-provider-attempt.md",
    "docs/archive/audits/dev238-retained-provider-attempt-root-cause-audit.md",
):
    require((ROOT / path).is_file(), f"missing governance file: {path}")

print("PASS: dev.238 retained orphaned provider attempt")

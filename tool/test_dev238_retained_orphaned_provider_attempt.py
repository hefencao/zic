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

m = re.search(r"^version:\s*0\.31\.0\+(\d+)\s*$", pubspec, re.M)
require(m is not None and int(m.group(1)) >= 238, "App build must be >=238")
m2 = re.search(r"^versionCode=(\d+)\s*$", props, re.M)
require(m2 is not None and int(m2.group(1)) == int(m.group(1)), "Android versionCode must match App build")

require("final providerOrphaned = activeClaim == null;" in owner, "provider claim orphaning must remain explicit")
require("if (providerOrphaned) return false;" in owner, "claim orphaning alone must not revoke an admitted provider task")
require("preferred.demand.priority > activeClaim.demand.priority" in owner, "live provider handoff must remain strict-priority only")
require("Only the provider consumer's real disposal boundary" in owner, "provider transport-owner disposal boundary must be explicit")
require(owner.count("net.cancel(key);") >= 1, "provider consumer disposal must still cancel transport before close")
require("providerKeys.add(key);\n      }\n    }\n    // Only the provider consumer's real disposal boundary" in owner, "dispose key collection must not duplicate the cancellation")

require("orphaned provider claim stays on the admitted task until provider disposal" in owner_test, "retained orphan provider behavior regression is required")
require("expect(newTransport.opened.isCompleted, isFalse);" in owner_test, "new exact provider must not open merely because the old claim detached")
require("expect(owner.activeProviderScope(physical), 'reader-old-provider');" in owner_test, "admitted provider lease must survive claim orphaning")
require("await oldReader.dispose();" in owner_test and "await newTransport.opened.future;" in owner_test, "real provider disposal must still rebind to the remaining consumer")
require("expect(identical(registry.find(exact), session), isTrue);" in owner_test, "provider disposal handoff must preserve the physical session")
require("expect(session.committedLength, greaterThan(0));" in owner_test, "provider disposal handoff must preserve committed partial bytes")

require("logical provider claim撤销 MUST NOT单独取消" in spec, "SPEC must separate claim and admitted-attempt lifetime")
require("claim lifetime不得再冒充transport lifetime" in architecture, "Architecture must name the corrected ownership boundary")

for path in (
    "docs/adr/0218-retained-orphaned-provider-attempt.md",
    "docs/audits/dev238-retained-provider-attempt-root-cause-audit.md",
):
    require((ROOT / path).is_file(), f"missing governance file: {path}")

print("PASS: dev.238 retained orphaned provider attempt")

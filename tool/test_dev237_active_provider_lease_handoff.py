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
progress_test = read("packages/pipeline_runtime/test/pipeline_transfer_progress_test.dart")

m = re.search(r"^version:\s*0\.31\.0\+(\d+)\s*$", pubspec, re.M)
require(m is not None and int(m.group(1)) >= 237, "App build must be >=237")
m2 = re.search(r"^versionCode=(\d+)\s*$", props, re.M)
require(m2 is not None and int(m2.group(1)) == int(m.group(1)), "Android versionCode must match App build")

require("_ActiveProviderLease" in owner, "active provider must be explicit task-scoped lease")
require("final Map<DownloadId, _ActiveProviderLease> _activeProviderLeases" in owner, "owner must keep one physical-id provider lease map")
require("claimSequence" in owner and "taskKey" in owner, "provider lease must identify task and claim generation")
require("_handoffActiveProviderIfNeeded(" in owner, "claim changes must evaluate provider handoff")
require("providerOrphaned" in owner, "orphaned provider claim must be detected")
require("preferred.demand.priority > activeClaim.demand.priority" in owner, "live provider handoff must require strict priority improvement")
require("net.cancel(taskKey);" in owner, "handoff must unwind old attempt through the one NetLane")
require("'stage': 'active-provider-handoff'" in owner, "handoff must be trace-visible")
require("_activeProviderScopes" not in owner, "scope-only provider state must be removed")
require("activeProviderExactId" in owner, "tests/diagnostics must expose the active exact provider")

require("new exact demand rebinds an orphaned retained provider to the shared partial" in owner_test, "orphaned retained provider behavior regression is required")
require("expect(identical(registry.find(exact), session), isTrue);" in owner_test, "test must prove physical session is preserved")
require("expect(session.committedLength, greaterThan(0));" in owner_test, "test must prove handoff retains partial bytes")
require("expect(owner.activeProviderScope(physical), 'reader-new-provider');" in owner_test, "test must prove provider scope rebind")
require("expect(owner.activeProviderExactId(physical), exact);" in owner_test, "test must prove provider exact identity rebind")

require("await session.append(" in progress_test and "1024 + 64 * 1024" in progress_test, "progress behavior test must prove future committed growth propagates after physical selection")

for path in (
    "docs/adr/0217-active-provider-lease-handoff.md",
    "docs/audits/dev237-active-provider-lease-root-cause-audit.md",
    "docs/audits/dev237-validation-results.md",
):
    require((ROOT / path).is_file(), f"missing governance file: {path}")

print("PASS: dev.237 active provider lease handoff")

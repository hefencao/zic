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
progress = read("packages/pipeline_runtime/lib/src/pipeline_transfer_progress.dart")
reader = read("packages/pipeline_runtime/lib/src/pipeline_reader_session.dart")
ingress = read("packages/sessions/lib/src/download_ingress_registry.dart")
test = read("packages/pipeline_runtime/test/pipeline_transfer_progress_test.dart")

m = re.search(r"^version:\s*0\.31\.0\+(\d+)\s*$", pubspec, re.M)
require(m is not None and int(m.group(1)) >= 236, "App build must be >=236")
m2 = re.search(r"^versionCode=(\d+)\s*$", props, re.M)
require(m2 is not None and int(m2.group(1)) == int(m.group(1)), "Android versionCode must match App build")

require("DownloadSession? _selectedSession;" in progress, "publisher must select physical DownloadSession directly")
require("void select(DownloadSession? session)" in progress, "publisher select must accept resolved physical session")
require("Map<String, DownloadSession> _sessions" not in progress, "exact-key session mirror must be removed")
require("_currentKey" not in progress, "logical exact progress key must be removed")
require("void observe(" not in progress, "all-session progress observer fan-out must be removed")
require("transferProgress.observe" not in reader, "Reader session must not repopulate progress mirror")

accept = reader.find("binding.accept(observation);")
select = reader.find("transferProgress.select(_downloads.find(currentDownload));")
require(accept >= 0 and select > accept, "progress must resolve physical alias after demand reconcile")
require("scopeId: '$scopePrefix:physical:${session.sessionId}'" in ingress, "ingress lifecycle scope must use physical session id")
require("scopeId: '$scopePrefix:${session.id.key}'" not in ingress, "ingress scope must not masquerade as exact physical-anchor id")

require("publisher follows resolved physical session for an exact alias" in test, "alias progress behavior regression is required")
require("publisher.select(registry.find(aliasId));" in test, "test must select registry-resolved physical session")
require("expect(registry.find(aliasId), same(session));" in test, "test must prove alias resolves to the physical session")
build = int(m.group(1))
if build >= 289:
    require("expect(publisher.feed.value.partialBytes, 1024);" in test, "test must prove inherited authoritative partial progress")
    require("expect(publisher.feed.value.transportBytes, 512);" in test, "test must keep transient transport cursor distinct from inherited partial")
elif build >= 244:
    require("expect(publisher.notifier.value.partialBytes, 1024);" in test, "test must prove inherited authoritative partial progress")
    require("expect(publisher.notifier.value.transportBytes, 512);" in test, "test must keep transient transport cursor distinct from inherited partial")
else:
    require("expect(publisher.notifier.value.committedBytes, 1024);" in test, "test must prove inherited committed progress")

for path in (
    "docs/adr/0216-physical-partial-progress-projection.md",
    "docs/audits/dev236-partial-progress-authority-root-cause-audit.md",
    "docs/audits/dev236-validation-results.md",
):
    require((ROOT / path).is_file(), f"missing governance file: {path}")

print("PASS: dev.236 physical partial progress projection closure")

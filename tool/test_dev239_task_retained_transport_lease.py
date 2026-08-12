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
runtime = read("packages/downloads/lib/src/composition_download_transfer_runtime.dart")
reader = read("packages/pipeline_runtime/lib/src/pipeline_reader_session.dart")
owner_test = read("packages/sessions/test/download_transfer_owner_test.dart")
spec = read("docs/SPEC.md")
architecture = read("docs/ARCHITECTURE.md")

m = re.search(r"^version:\s*0\.31\.0\+(\d+)\s*$", pubspec, re.M)
require(m is not None and int(m.group(1)) >= 239, "App build must be >=239")
m2 = re.search(r"^versionCode=(\d+)\s*$", props, re.M)
require(m2 is not None and int(m2.group(1)) == int(m.group(1)), "Android versionCode must match App build")

require("typedef TransferRetainedTransportPick = Transport? Function(Uri uri);" in owner, "sessions must expose a generic retainable transport capability")
require("TransferRetainedTransportPick? retainedTransportFor" in owner, "consumer attach must accept retainable transport resolver")
require("transportRetainedBeyondConsumer" in owner, "active provider lease must record transport lifetime")
require("'providerTransportLifetime': retainedTransport != null" in owner, "transport lifetime must be trace-visible")
require("entry.value.transportRetainedBeyondConsumer" in owner, "consumer dispose barrier must skip task-retained transport leases")
require("TransferRetainedTransportPick? retainedTransportFor" in runtime, "downloads composition runtime must forward generic transport capability")

require("retainedTransportFor: _retainedTransferTransportFor" in reader, "Pipeline Reader must provide retainable transport capability")
require("Transport? _retainedTransferTransportFor(Uri uri)" in reader, "Pipeline retained transport resolver must be explicit")
require("_loaderTransport.contains(uri) ? _transportFor(uri) : null" in reader, "only loader-backed URIs may be retained across Reader disposal")
resolver = reader.split("Transport? _retainedTransferTransportFor(Uri uri)", 1)[1].split("void _observeDownloadSession", 1)[0]
require("_ioTransport" not in resolver, "Reader IoTransport must never be returned by retained resolver")
require("Reader-owned IoTransport is" in reader and "excluded" in reader, "Reader close boundary must be documented beside retained resolver")

require("task-retained transport survives provider consumer disposal on shared partial" in owner_test, "task-retained behavior regression is required")
require("expect(retainedTransport.cancelled.isCompleted, isFalse);" in owner_test, "retained transport must survive provider consumer disposal")
require("expect(replacementTransport.opened.isCompleted, isFalse);" in owner_test, "remaining logical provider must not reopen while retained task is valid")
require("expect(identical(registry.find(exact), session), isTrue);" in owner_test, "retained task must preserve physical session identity")
require("expect(session.committedLength, fullBytes.length);" in owner_test, "retained task must finish through the same physical committed authority")
require("disposing active provider preserves remaining consumer and reopens once" in owner_test, "consumer-bound transport disposal regression must remain")
require("await transportA.cancelled.future;" in owner_test and "expect(transportB.opens, 1);" in owner_test, "consumer-bound transport must still cancel and reopen through remaining provider")

require("task-retainable transport capability" in spec, "SPEC must define the retainable transport contract")
require("Reader-owned `IoTransport` MUST始终属于此类" in spec, "SPEC must preserve the Reader IO close barrier")
require("retainedTransportFor(uri)" in architecture, "Architecture must name the generic retained transport capability")
require("sessions不得知道Venera/Mihon/source类型" in architecture, "Architecture must prohibit source-specific branching in sessions")

for path in (
    "docs/adr/0219-task-retained-loader-transport-lease.md",
    "docs/audits/dev239-task-retained-transport-root-cause-audit.md",
):
    require((ROOT / path).is_file(), f"missing governance file: {path}")

print("PASS: dev.239 task-retained loader transport lease")

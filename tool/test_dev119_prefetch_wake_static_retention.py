#!/usr/bin/env python3
"""Guard dev.119 prefetch source-wake and static output retention."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, owner: str) -> None:
    if token not in text:
        raise SystemExit(f"{owner} is missing dev.119 contract: {token}")

role_window = read("packages/pipeline/lib/src/role_window.dart")
heuristic = read("packages/pipeline/lib/src/heuristic_policy.dart")
refill = read("packages/sessions/lib/src/decode_refill_policy.dart")
coordinator = read("packages/sessions/lib/src/live_coordinator.dart")
upload = read("packages/sessions/lib/src/upload_session.dart")
registry = read("packages/sessions/lib/src/upload_registry.dart")
budget = read("packages/sessions/lib/src/frame_budget.dart")
reader = read("packages/reader/lib/src/reader_view.dart")
trace = read("packages/telemetry/lib/src/trace.dart")
analyzer = read("tool/analyze_frame_pipeline_trace.py")
refill_test = read("packages/sessions/test/decode_refill_policy_test.dart")
coordinator_test = read("packages/sessions/test/live_coordinator_test.dart")
upload_test = read("packages/sessions/test/upload_session_test.dart")
budget_test = read("packages/sessions/test/frame_budget_test.dart")
check = read("tool/check.sh")

for text, token, owner in (
    (refill, "DecodeEligibilityLookup", "decode refill policy"),
    (refill, "eligibleOf(entry.key)", "single-frame eligibility"),
    (refill, "!eligibleOf(id)", "staged eligibility"),
    (coordinator, "bool _hasPendingSourceRevision", "source wake tracking"),
    (coordinator, "snapshot.state != DecodeState.waitingSource ||", "blocked refill filtering"),
    (coordinator, "_hasPendingSourceRevision(decision.id)", "refill wake preservation"),
    (upload, "bool get hasRetainableStaticOutput", "static output ownership"),
    (upload, "bool detach({bool retainStaticOutput = false})", "static detach contract"),
    (upload, "TraceEventKind.staticFrameKept", "static keep trace"),
    (registry, "bool retainStaticOutput = false", "upload registry retention"),
    (budget, "final aPriority = demands[a.id]?.priority ?? -1", "budget-owned dormant eviction"),
    (reader, "_verticalCacheScreens = 2", "vertical host warmup extent"),
    (reader, ".abs() <= 7", "prefetch-aligned host retention"),
    (trace, "staticFrameKept", "telemetry event"),
    (analyzer, '"staticFrameKeptCount"', "trace analyzer"),
    (refill_test, "current source wait suppresses speculative neighbor decode bootstrap", "refill owner test"),
    (coordinator_test, "revisit reuses the retained static output", "coordinator owner test"),
    (upload_test, "detached authoritative static output remains until budget trim", "upload owner test"),
    (budget_test, "undemanded output remains until the byte budget is exceeded", "budget owner test"),
    (check, "test_dev119_prefetch_wake_static_retention.py", "repository check"),
):
    require(text, token, owner)

for text, owner in (
    (role_window, "role window"),
    (heuristic, "heuristic policy"),
    (budget, "frame budget"),
):
    if "PageRole.visible" in text:
        raise SystemExit(f"{owner} still contains the superseded visible-role workaround")

if "visible," in role_window:
    raise SystemExit("PageRole.visible enum member was not removed")

print("dev.119 prefetch wake and static retention contract: OK")

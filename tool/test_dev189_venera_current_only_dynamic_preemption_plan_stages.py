#!/usr/bin/env python3
"""Guard dev.189 current-only dynamic Venera preemption and plan stage diagnostics."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f"{path} missing dev.189 contract: {missing}")


runtime = read("packages/plugin_host/lib/src/runtime_source_adapter.dart")
require(
    "packages/plugin_host/lib/src/runtime_source_adapter.dart",
    "dynamicPreemptionPriorityThreshold:",
    "? 1000",
    "observedPriority < dynamicPreemptionPriorityThreshold",
    "priority >= dynamicPreemptionPriorityThreshold",
    "sourcePlanGateWaitMicros",
    "sourcePlanRuntimeInvocationMicros",
)
if "activeControl.priorityChanges.listen" in runtime:
    raise SystemExit("active Venera demotion must not dynamically preempt plans")

require(
    "packages/plugin_host/test/runtime_source_adapter_test.dart",
    "transition jitter must not cause irreversible plan cancellation",
    "promotedControl.updatePriority(900)",
    "promotedControl.updatePriority(780)",
    "promotedControl.updatePriority(1000)",
    "active Venera demotion does not turn viewport jitter into plan preemption",
    "active demotion is reversible viewport state and must not cancel",
)
require(
    "packages/catalog/lib/src/source_catalog.dart",
    "final Map<String, Object?> diagnostics;",
    "diagnostics = Map<String, Object?>.unmodifiable(diagnostics)",
    "cache, retry and scheduling policy must not depend on these values",
)
require(
    "packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraRuntimeDriver.kt",
    "const __zicBridgeMetrics=new Map();",
    "sourcePlanHookMicros",
    "sourcePlanBridgeNetworkMicros",
    "sourcePlanBridgeNetworkCalls",
    "__zicBridgeMetrics.delete(request.requestId)",
)
require(
    "packages/downloads/lib/src/source_resource_transport.dart",
    "final sourcePlanDiagnostics = resolved.cacheHit",
    "...sourcePlanDiagnostics",
    "diagnostics: request.diagnostics",
    "diagnostics: spec.diagnostics",
)
require(
    "packages/downloads/test/source_resource_transport_test.dart",
    "sourcePlanGateWaitMicros",
    "sourcePlanRuntimeInvocationMicros",
    "sourcePlanHookMicros",
    "sourcePlanBridgeNetworkMicros",
    "sourcePlanBridgeNetworkCalls",
)
require(
    "tool/test_venera_bootstrap.py",
    "checkRequestPlanStageDiagnostics",
    "sourcePlanBridgeNetworkCalls!==1",
    "__zicBridgeMetrics.has(requestId)",
)
require(
    "docs/adr/0172-venera-current-only-dynamic-preemption-and-plan-stage-observation.md",
    "current=1000",
    "780↔900",
    "sourcePlanGateWaitMicros",
    "sourcePlanBridgeNetworkMicros",
)
require("tool/check.sh", "test_dev189_venera_current_only_dynamic_preemption_plan_stages.py")

pubspec = read("apps/app/pubspec.yaml")
version_match = re.search(r"^version:\s*0\.31\.0\+(\d+)\s*$", pubspec, re.MULTILINE)
if not version_match or int(version_match.group(1)) < 189:
    raise SystemExit("app version is below dev.189")
android = read("apps/app/android/zic-version.properties")
android_match = re.search(r"^versionCode=(\d+)\s*$", android, re.MULTILINE)
if android_match is None or android_match.group(1) != version_match.group(1):
    raise SystemExit("Android versionCode and App build must match")

print("dev.189 Venera current-only dynamic preemption / plan stages: OK")

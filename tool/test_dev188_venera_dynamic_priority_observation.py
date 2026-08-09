#!/usr/bin/env python3
"""Guard dev.188 Venera dynamic-priority propagation and request-plan ownership."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f"{path} missing dev.188 contract: {missing}")

require(
    "packages/domain/lib/src/task_control.dart",
    "abstract interface class PriorityObservableTaskControl implements TaskControl",
    "Stream<int> get priorityChanges;",
)
require(
    "packages/sessions/lib/src/net_lane.dart",
    "final class CancelToken implements PriorityObservableTaskControl",
    "StreamController<int>.broadcast(sync: true)",
    "_priorityChanges.add(priority)",
    "removed?.token.dispose();",
)
require(
    "packages/plugin_host/lib/src/runtime_source_adapter.dart",
    "if (taskControl is PriorityObservableTaskControl)",
    "waiter.prioritySubscription = taskControl.priorityChanges.listen",
    "_maybePreemptControlledActive(waiter.control)",
    "disposePrioritySubscription()",
)
require(
    "packages/plugin_host/test/runtime_source_adapter_test.dart",
    "queued Venera request promoted to current re-evaluates active preemption",
    "promotedControl.updatePriority(1000)",
    "active Venera demotion does not turn viewport jitter into plan preemption",
    "activeControl.updatePriority(700)",
    "expect(connection.maxActive, 1)",
)
require(
    "packages/sessions/test/net_lane_test.dart",
    "active rank migration emits the scheduler-owned priority signal",
    "expect(await observed.future, 1000)",
)
require(
    "packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraRuntimeDriver.kt",
    "This requestId belongs to the JavaScript request-plan invocation, not",
    "final image-body transport",
    "SourceResourceTransport",
    "bridge.cancel(requestId)",
    "__zicCancel",
)
require(
    "docs/adr/0171-venera-dynamic-priority-observation.md",
    "PriorityObservableTaskControl",
    "onImageLoad",
    "最终图片HTTP",
    "maxConcurrentInvocations=1",
)
require("tool/check.sh", "test_dev188_venera_dynamic_priority_observation.py")

pubspec = read("apps/app/pubspec.yaml")
version_match = re.search(r"^version:\s*0\.31\.0\+(\d+)\s*$", pubspec, re.MULTILINE)
if not version_match or int(version_match.group(1)) < 188:
    raise SystemExit("app version is below dev.188")
android = read("apps/app/android/zic-version.properties")
android_match = re.search(r"^versionCode=(\d+)\s*$", android, re.MULTILINE)
if android_match is None or android_match.group(1) != version_match.group(1):
    raise SystemExit("Android versionCode and App build must match")

print("dev.188 Venera dynamic priority observation: OK")

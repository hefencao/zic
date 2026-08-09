#!/usr/bin/env python3
"""Guard dev.190 runtime resource-plan timing compile/coupling boundary."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "packages/plugin_host/lib/src/runtime_source_adapter.dart"
text = RUNTIME.read_text(encoding="utf-8")


def require(token: str) -> None:
    if token not in text:
        raise SystemExit(f"runtime source adapter missing dev.190 contract: {token}")


match = re.search(
    r"typedef _RuntimeInvoke = Future<Object> Function\((.*?)\n\}\);",
    text,
    re.DOTALL,
)
if match is None:
    raise SystemExit("generic _RuntimeInvoke typedef not found")
if "onTiming" in match.group(1) or "Timing" in match.group(1):
    raise SystemExit("generic _RuntimeInvoke must not expose resource-plan timing")

if "onTiming" in text:
    raise SystemExit("callback-style onTiming half-migration must not return")

for token in (
    "typedef _RuntimeResolveResourceInvoke =",
    "Future<_RuntimeInvocationResult> Function(",
    "resolveResourceInvoke: _resolveResourceInvocation",
    "final _RuntimeResolveResourceInvoke _resolveResourceInvoke;",
    "final invocation = await _resolveResourceInvoke(",
    "Future<_RuntimeInvocationResult> _invokeMeasured(",
    "Future<_RuntimeInvocationResult> _resolveResourceInvocation(",
    "sourcePlanGateWaitMicros': invocation.gateWaitMicros",
    "invocation.runtimeInvocationMicros",
):
    require(token)

# Source-plan diagnostics may cross plugin_host -> downloads for trace, but may
# not become a scheduler/Reader/App policy channel.
explicit_keys = (
    "sourcePlanGateWaitMicros",
    "sourcePlanRuntimeInvocationMicros",
    "sourcePlanHookMicros",
    "sourcePlanBridgeNetworkMicros",
    "sourcePlanBridgeNetworkCalls",
)
for relative in (
    "packages/sessions/lib",
    "packages/pipeline_runtime/lib",
    "apps/app/lib",
):
    base = ROOT / relative
    for path in base.rglob("*.dart"):
        body = path.read_text(encoding="utf-8")
        hits = [key for key in explicit_keys if key in body]
        if hits:
            raise SystemExit(
                f"source-plan diagnostics leaked into policy layer {path.relative_to(ROOT)}: {hits}"
            )

catalog = (ROOT / "packages/catalog/lib/src/source_catalog.dart").read_text(
    encoding="utf-8"
)
if "cache, retry and scheduling policy must not depend on these values" not in catalog:
    raise SystemExit("ComicResourceRequest diagnostics read-only contract missing")

print("dev.190 runtime resource-plan timing compile/coupling boundary: OK")

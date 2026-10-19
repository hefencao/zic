#!/usr/bin/env python3
"""Guard dev.187 Venera request-scoped physical cancel/unwind ownership."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f"{path} missing dev.187 contract: {missing}")

def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    if present:
        raise SystemExit(f"{path} contains blocking/superseded dev.187 token: {present}")

venera_path = "packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraRuntimeDriver.kt"

pubspec_now = read("apps/app/pubspec.yaml")
build_now = int(re.search(r"^version:\s*\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)\s*$", pubspec_now, re.MULTILINE).group(1))
if build_now >= 206:
    require(
        venera_path,
        "resolverHttp.cancel(requestId)",
        "function __zicCancelDelays(requestId)",
        "function __zicCancelBridgeWaiters(requestId)",
        "requestId=message.requestId??__zicActiveRequestId",
        "__zicBridgeWaiters.set(callId,{resolve,reject,requestId})",
        "function __zicCancel(requestId){__zicCancelled.add(requestId);__zicCancelDelays(requestId);__zicCancelBridgeWaiters(requestId)}",
        "bridge.cancel(requestId)",
        "finishedSink?.invoke(requestId)",
        "invocationDrain.beginCall(transportRequestId, callId, activation = requestId == null)",
        "invocationDrain.endCall(transportRequestId, callId)",
        "invocationDrain.finish(requestId)",
        "invocationDrain.complete(requestId, it)",
        "if (closed || cancelled.contains(requestId)) return@withNativeWork",
    )
    resolver = read("packages/plugin_host_bridge/lib/src/venera_resolver_http_service.dart")
    for token in ("final cancelToken = rhttp.CancelToken()", "active.cancelToken.cancel()", "requestStream("):
        if token not in resolver:
            raise SystemExit(f"dev.187 superseded cancellation contract missing: {token}")
    require("packages/plugin_host/lib/src/runtime_executors.dart", "maxConcurrentInvocations: 1")
    require("tool/test_venera_bootstrap.py", "checkRequestScopedDelayCancellation", "elapsed>500")
    print("dev.187 request-scoped cancel semantics: superseded transport verified by dev.206")
    raise SystemExit(0)
require(
    venera_path,
    "is InputStream -> runCatching { connection.close() }",
    "registerConnection(requestId, it)",
    "unregisterConnection(requestId, it)",
    "const __zicBrowserSetTimeout=globalThis.setTimeout.bind(globalThis);",
    "const __zicDelayWaiters=new Map();",
    "function __zicDelay(time,requestId)",
    "if(message.method==='delay')return __zicDelay(message.time,requestId);",
    "function __zicCancelDelays(requestId)",
    "function __zicCancelBridgeWaiters(requestId)",
    "requestId=message.requestId??__zicActiveRequestId",
    "__zicBridgeWaiters.set(callId,{resolve,reject,requestId})",
    "function __zicCancel(requestId){__zicCancelled.add(requestId);__zicCancelDelays(requestId);__zicCancelBridgeWaiters(requestId)}",
    "bridge.cancel(requestId)",
    "finishedSink?.invoke(requestId)",
)
reject(
    venera_path,
    'Thread.sleep(message.optLong("time", 0).coerceIn(0, 30_000))',
)
venera = read(venera_path)
if venera.count("registerConnection(requestId, it)") < 2:
    raise SystemExit("both URLConnection and DNS-fallback body streams must join request-scoped cancellation")
if venera.count("unregisterConnection(requestId, it)") < 2:
    raise SystemExit("request-scoped body streams must be unregistered after read completion")

require(
    "packages/plugin_host/lib/src/runtime_executors.dart",
    "maxConcurrentInvocations: 1",
)
require(
    "tool/test_venera_bootstrap.py",
    "checkRequestScopedDelayCancellation",
    "elapsed>500",
)
require(
    "docs/archive/adr/0170-venera-request-scoped-cancel-unwind.md",
    "InputStream",
    "Thread.sleep",
    "maxConcurrentInvocations=1",
)
require("tool/check.sh", "test_dev187_venera_request_scoped_cancel_unwind.py")

pubspec = read("apps/app/pubspec.yaml")
version_match = re.search(r"^version:\s*\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)\s*$", pubspec, re.MULTILINE)
if not version_match or int(version_match.group(1)) < 187:
    raise SystemExit("app version is below dev.187")
android = read("apps/app/android/zic-version.properties")
android_match = re.search(r"^versionCode=(\d+)\s*$", android, re.MULTILINE)
if android_match is None or android_match.group(1) != version_match.group(1):
    raise SystemExit("Android versionCode and App build must match")

print("dev.187 Venera request-scoped cancel unwind: OK")

#!/usr/bin/env python3
"""Guard Venera's image fast path against Base64/JS and request-body regressions."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraRuntimeDriver.kt'
text = SOURCE.read_text(encoding='utf-8')

required = (
    '"http_binary" -> httpBinary(message)',
    'fun takeNativeBytes(token: String): ByteArray?',
    'private fun retainNativeBytes(bytes: ByteArray): String',
    'VENERA_MAX_NATIVE_BYTE_PAYLOADS',
    'function __zicNetworkPayload(method,data)',
    'function __zicDescribeResourceRequest(config)',
    'async function __zicRetryResourceConfig(uri,source)',
    "if(request.operation==='retryResource')",
    'fetchBinary:async(method,url,headers,data)',
    "return {__zicNativeBytesToken:direct.nativeBytesToken}",
    'if (method in setOf("GET", "HEAD")) {',
    'bodyBytes = ByteArray(0)',
    'forwardHeaders.removeVeneraHeader("content-length")',
    'VENERA_HTTP_MAX_REQUEST_BYTES',
    'VENERA_HTTP_READ_TIMEOUT_MILLIS = 45_000',
    'VENERA_HTTP_CALL_TIMEOUT_MILLIS = 50_000L',
    'private val requestConnections =',
    'requestConnections[requestId]?.toList()?.forEach(::cancelConnection)',
    'registerConnection(requestId, connection)',
    'unregisterConnection(requestId, connection)',
    'let __zicActiveRequestId=null;',
    'ZicNative.finished(request.requestId)',
)
for token in required:
    if token not in text:
        raise SystemExit(f'Venera native binary contract is missing: {token}')

load_resource = text.split("if(request.operation==='loadResource')", 1)[1]
load_resource = load_resource.split("throw new Error('Unsupported Venera operation')", 1)[0]
if load_resource.find('Network.fetchBinary') > load_resource.find('Network.fetchBytes'):
    raise SystemExit('Venera direct binary path must precede the JS byte fallback')
if "typeof active.onResponse==='function'" not in load_resource:
    raise SystemExit('Venera transformed responses lost the JS compatibility path')
if "typeof active.modifyImage==='string'" not in load_resource:
    raise SystemExit('Venera image modifiers lost the JS compatibility path')

describe = text.split('function __zicDescribeResourceRequest(config)', 1)[1]
describe = describe.split('async function __zicRetryResourceConfig', 1)[0]
if "typeof config.onLoadFailed==='function'" in describe:
    raise SystemExit(
        'Venera onLoadFailed must not force the complete image body through RPC'
    )

transport = (ROOT / 'packages/downloads/lib/src/source_resource_transport.dart').read_text(
    encoding='utf-8'
)
for token in (
    'RetryableComicResourceSource',
    'retryable.retryResource(locator)',
    '_client.autoUncompress = false',
):
    if token not in transport:
        raise SystemExit(f'Venera streaming retry contract is missing: {token}')

executor = (ROOT / 'packages/plugin_host/lib/src/runtime_executors.dart').read_text(
    encoding='utf-8'
)
for token in (
    'invocationTimeout: Duration(seconds: 55)',
    'maxConcurrentInvocations: 1',
):
    if token not in executor:
        raise SystemExit(f'Venera executor bound is missing: {token}')

print('Venera native binary and request-bound contract: OK')

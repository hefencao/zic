#!/usr/bin/env python3
"""Guard Venera's image fast path against Base64/JS and request-body regressions."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraRuntimeDriver.kt'
text = SOURCE.read_text(encoding='utf-8')

required = (
    '"http_binary" -> httpBinary(message, requireImage = false)',
    '"http_image_binary" -> httpBinary(message, requireImage = true)',
    'fun takeNativeBytes(token: String): ByteArray?',
    'private fun retainNativeBytes(bytes: ByteArray, message: JSONObject): String',
    'VENERA_MAX_NATIVE_BYTE_PAYLOADS',
    'hasVeneraEncodedImageSignature(response.body)',
    '.put("encodedImage", encodedImage)',
    'networkCache.invalidate(',
    'forceResolverCacheMiss = message.optBoolean("__zicFreshResolver", false)',
    'forceMiss = forceResolverCacheMiss',
    'let __zicFreshResolverDepth=0;',
    'message.__zicFreshResolver!==true',
    'function __zicNetworkPayload(method,data)',
    'function __zicDescribeResourceRequest(config)',
    'async function __zicRetryResourceConfig(uri,source)',
    'const __zicSemanticRetryLimit=5;',
    '__zicSemanticRetryCount:retryCount+1',
    "if(request.operation==='retryResource')",
    'fetchBinary:async(method,url,headers,data)',
    "async function __zicFetchImageBinary(method,url,headers,data){return sendMessage({method:'http_image_binary'",
    "return {__zicNativeBytesToken:direct.nativeBytesToken}",
    "if(direct.encodedImage===false)throw new Error('Venera resource returned non-image bytes')",
    'if (method in setOf("GET", "HEAD")) {',
    'bodyBytes = ByteArray(0)',
    'forwardHeaders.removeVeneraHeader("content-length")',
    'VENERA_HTTP_MAX_REQUEST_BYTES',
    'let __zicActiveRequestId=null;',
    'ZicNative.finished(request.requestId)',
)
for token in required:
    if token not in text:
        raise SystemExit(f'Venera native binary contract is missing: {token}')
for stale in ('__zicSemanticRetryConsumed', '__zicResolveFreshResourceConfig'):
    if stale in text:
        raise SystemExit(f'Venera native binary still contains one-shot semantic recovery: {stale}')

resolver = (ROOT / 'packages/plugin_host_bridge/lib/src/venera_resolver_http_service.dart').read_text(encoding='utf-8')
resolver_transport = (ROOT / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraResolverHttpTransport.kt').read_text(encoding='utf-8')
for token in ('rhttp.RhttpClient.create', 'requestStream(', 'final cancelToken = rhttp.CancelToken()'):
    if token not in resolver:
        raise SystemExit(f'Venera native binary resolver rhttp contract missing: {token}')
for token in ('VENERA_RESOLVER_RPC_TIMEOUT_SECONDS = 55L', 'veneraResolverHttpCancel'):
    if token not in resolver_transport:
        raise SystemExit(f'Venera native binary resolver bound missing: {token}')

load_resource = text.split("if(request.operation==='loadResource')", 1)[1]
load_resource = load_resource.split("throw new Error('Unsupported Venera operation')", 1)[0]
if load_resource.find('__zicFetchImageBinary') > load_resource.find('Network.fetchBytes'):
    raise SystemExit('Venera image binary path must precede the JS byte fallback')
if "fetchBinary:async(method,url,headers,data)=>sendMessage({method:'http_binary'" not in text:
    raise SystemExit('public Venera fetchBinary was narrowed away from generic http_binary')
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
    'ControlledRetryableComicResourceSource',
    '.retryResource(locator)',
    'controlled.retryResourceControlled(locator, control: control)',
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

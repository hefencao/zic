#!/usr/bin/env python3
"""Compile the production Venera response-header adapter against nullable/non-null maps."""
import re
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (
    root
    / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraRuntimeDriver.kt'
).read_text()
match = re.search(
    r'(private fun veneraResponse\(.*?\n\})\n\nprivate fun JSONObject',
    source,
    re.S,
)
if not match:
    raise SystemExit('veneraResponse helper not found')
for token in (
    'defaultUserAgent = webView.settings.userAgentString.orEmpty()',
    'veneraRequestHeaders(',
    'message.optJSONObject("headers")',
    'headers.keys.none { it.equals("user-agent", ignoreCase = true) }',
    'headers["User-Agent"] = defaultUserAgent',
    'repeat(VENERA_HTTP_MAX_REDIRECTS + 1)',
    'persistResponseCookies(targetIdentity, result.optJSONObject("headers"))',
    '.veneraHeaderValue("location")',
    'forwardHeaders.removeVeneraHeader("authorization")',
    'connection.instanceFollowRedirects = false',
    'it.name == "followRedirects"',
    'it.name == "followSslRedirects"',
):
    if token not in source:
        raise SystemExit(
            f'Venera native HTTP default user-agent contract is missing: {token}'
        )
helper = match.group(1)

with tempfile.TemporaryDirectory() as directory:
    work = Path(directory)
    (work / 'JSONObject.kt').write_text(
        '''package org.json
class JSONObject {
    private val values = linkedMapOf<String, Any?>()
    fun put(name: String, value: Any?): JSONObject { values[name] = value; return this }
    override fun toString(): String = values.toString()
}
'''
    )
    (work / 'Smoke.kt').write_text(
        '''import org.json.JSONObject
private fun encodeWireValue(value: Any?): Any? = value
'''
        + helper
        + '''
fun main() {
    val strict: Map<String, List<String>> = mapOf("content-type" to listOf("image/jpeg"))
    val nullable: Map<String?, List<String>?> = mapOf("set-cookie" to listOf("a=1"), null to null)
    check(veneraResponse(200, strict, byteArrayOf(1, 2), true).toString().contains("content-type"))
    check(veneraResponse(200, nullable, byteArrayOf(), false).toString().contains("set-cookie"))
    println("Venera response header adapter: OK")
}
'''
    )
    jar = work / 'smoke.jar'
    subprocess.run(
        ['kotlinc', str(work / 'JSONObject.kt'), str(work / 'Smoke.kt'), '-include-runtime', '-d', str(jar)],
        check=True,
    )
    subprocess.run(['java', '-jar', str(jar)], check=True)

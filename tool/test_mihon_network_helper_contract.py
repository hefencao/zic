#!/usr/bin/env python3
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


common_root = (
    'packages/plugin_host_bridge/android/src/mihonRuntimeCommon/kotlin/'
    'eu/kanade/tachiyomi/network/interceptor/'
)
interceptor = read(common_root + 'UncaughtExceptionInterceptor.kt')
for token in (
    'package eu.kanade.tachiyomi.network.interceptor',
    'class UncaughtExceptionInterceptor : Interceptor',
    'catch (error: Exception)',
    'if (error is IOException)',
    'throw error',
    'throw IOException(error)',
):
    if token not in interceptor:
        raise SystemExit(f'Mihon uncaught-exception interceptor contract missing: {token}')

user_agent = read(common_root + 'UserAgentInterceptor.kt')
for token in (
    'class UserAgentInterceptor(',
    'originalRequest.header("User-Agent").isNullOrEmpty()',
    '.addHeader("User-Agent", defaultUserAgentProvider())',
):
    if token not in user_agent:
        raise SystemExit(f'Mihon User-Agent interceptor contract missing: {token}')

cloudflare = read(common_root + 'CloudflareInterceptor.kt')
for token in (
    'class CloudflareInterceptor(',
    'private val delegate: Interceptor',
    'delegate.intercept(chain)',
):
    if token not in cloudflare:
        raise SystemExit(f'Mihon Cloudflare ABI shell contract missing: {token}')

for abi in ('mihonRuntime14', 'mihonRuntime16'):
    path = (
        'packages/plugin_host_bridge/android/src/'
        f'{abi}/kotlin/eu/kanade/tachiyomi/network/RuntimeNetwork.kt'
    )
    source = read(path)
    for name in (
        'UncaughtExceptionInterceptor',
        'UserAgentInterceptor',
        'CloudflareInterceptor',
    ):
        import_token = (
            'import eu.kanade.tachiyomi.network.interceptor.'
            f'{name}'
        )
        if import_token not in source:
            raise SystemExit(
                f'{abi} NetworkHelper misses canonical {name} import',
            )

    builder = source.index('OkHttpClient.Builder()')
    uncaught = source.index(
        '.addInterceptor(UncaughtExceptionInterceptor())',
        builder,
    )
    user_agent = source.index(
        '.addInterceptor(UserAgentInterceptor(::defaultUserAgentProvider))',
        builder,
    )
    cookie = source.index('.cookieJar(cookieJar)', builder)
    browser_ua = source.index('.addInterceptor { chain ->', builder)
    cloudflare = source.index(
        '.addInterceptor(\n                CloudflareInterceptor(',
        builder,
    )
    delegate = source.index(
        'AndroidCloudflareInterceptor(context, ::defaultUserAgentProvider)',
        cloudflare,
    )
    if 'BrotliInterceptor' in source:
        raise SystemExit(f'{abi} default NetworkHelper must not install BrotliInterceptor')
    if not (
        builder < uncaught < user_agent < cookie < browser_ua
        < cloudflare < delegate
    ):
        raise SystemExit(
            f'{abi} NetworkHelper must keep the canonical Mihon default-client '
            'interceptors in order while delegating Cloudflare policy to '
            'network_bridge',
        )

build = read('packages/plugin_host_bridge/android/build.gradle')
if 'fileTree(mihonRuntimeCommonSources)' not in build:
    raise SystemExit('Mihon runtime-common sources are not compiled into ABI assets')


def verify_host_replay_capabilities() -> None:
    kotlinc = shutil.which('kotlinc')
    java = shutil.which('java')
    if not kotlinc or not java:
        print('SKIP: kotlinc/java unavailable for default-client host replay behavior')
        return
    driver = read('packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt')
    bodies = []
    for pattern in (
        r'internal fun mihonSourceRequiresRuntimeTransform\(.*?\n\}',
        r'private fun mihonHostReplaySafeClientCapability\(.*?\n\}',
        r'private fun Any.readValue\(.*?\n\}',
    ):
        match = re.search(pattern, driver, re.DOTALL)
        if match is None:
            raise SystemExit(f'Mihon host replay helper missing: {pattern}')
        bodies.append(match.group(0))
    harness = '''package dev.zic.pluginhost
import java.net.URLClassLoader
import java.io.File

private fun Any.invokeOptional(name: String): Any? = javaClass.methods
    .firstOrNull { it.name == name && it.parameterCount == 0 }?.invoke(this)
private class FixtureClient(private val application: List<Any>, private val network: List<Any>) {
    fun interceptors(): List<Any> = application
    fun networkInterceptors(): List<Any> = network
}
''' + '\n\n'.join(bodies) + '''
fun main(args: Array<String>) {
    val parent = FixtureClient::class.java.classLoader
    val loader = URLClassLoader(arrayOf(File(args.single()).toURI().toURL()), parent)
    val sourceType = loader.loadClass("plugin.FixtureSource")
    fun source(application: List<Any>, network: List<Any> = emptyList()): Any =
        sourceType.getConstructor(Any::class.java).newInstance(FixtureClient(application, network))
    val defaults = listOf(
        eu.kanade.tachiyomi.network.interceptor.UncaughtExceptionInterceptor(),
        eu.kanade.tachiyomi.network.interceptor.UserAgentInterceptor(),
        eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor(),
    )
    check(!mihonSourceRequiresRuntimeTransform(source(defaults))) {
        "canonical default Mihon client incorrectly forces complete runtime body RPC"
    }
    check(!mihonSourceRequiresRuntimeTransform(source(emptyList(), defaults)))
    check(mihonSourceRequiresRuntimeTransform(source(defaults + UnknownInterceptor())))
    val extensionOwned = loader.loadClass("plugin.CustomInterceptor").getConstructor().newInstance()
    check(mihonSourceRequiresRuntimeTransform(source(defaults + extensionOwned)))
    check(mihonSourceRequiresRuntimeTransform(source(defaults, listOf(extensionOwned))))
    for (interceptor in defaults) {
        check(mihonHostReplaySafeClientCapability("interceptor", interceptor))
    }
    check(!mihonHostReplaySafeClientCapability("interceptor", UnknownInterceptor()))
    loader.close()
    println("Mihon canonical default client streams on host; unknown/source-owned capability stays runtime: OK")
}
class UnknownInterceptor
'''
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        plugin = root / 'Plugin.kt'
        plugin.write_text('''package plugin
class FixtureSource(val client: Any)
class CustomInterceptor
''')
        plugin_jar = root / 'plugin.jar'
        subprocess.run([kotlinc, str(plugin), '-d', str(plugin_jar)], check=True)
        capabilities = root / 'Capabilities.kt'
        capabilities.write_text('''package eu.kanade.tachiyomi.network.interceptor
class UncaughtExceptionInterceptor
class UserAgentInterceptor
class CloudflareInterceptor
''')
        runner = root / 'ReplayBehavior.kt'
        runner.write_text(harness)
        output = root / 'replay.jar'
        subprocess.run([kotlinc, str(capabilities), str(runner), '-include-runtime', '-d', str(output)], check=True)
        subprocess.run([java, '-jar', str(output), str(plugin_jar)], check=True)


def verify_host_network_failure_classification() -> None:
    kotlinc = shutil.which('kotlinc')
    java = shutil.which('java')
    if not kotlinc or not java:
        raise SystemExit('Mihon network failure contract requires kotlinc and java')
    driver = read(
        'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/'
        'MihonRuntimeDriver.kt',
    )
    start = driver.index('private fun Throwable.isNetworkFailure()')
    end = driver.index('\nprivate fun formatInstant(', start)
    classification = driver[start:end]
    root_start = driver.index('private fun Throwable.rootCause()')
    root_end = driver.index('\nprivate fun Throwable.mihonDiagnosticMessage()', root_start)
    decision = re.search(r'val networkFailure = [^\n]+', driver)
    if decision is None:
        raise SystemExit('Mihon invocation network decision missing')
    harness = driver[root_start:root_end] + '\n' + classification + '''
private fun invocationNetworkFailure(error: Throwable): Boolean {
    val cause = error.rootCause()
    ''' + decision.group(0) + '''
    return networkFailure
}

fun main() {
    val nativeCause = IllegalStateException("ECONNREFUSED from native syscall")
    val connect = java.net.ConnectException("connection refused").apply {
        initCause(nativeCause)
    }
    check(invocationNetworkFailure(IllegalStateException("chapter failed", connect))) {
        "nested ConnectException lost network classification at a non-IO native cause"
    }
    val transportErrors = listOf(
        java.net.SocketException("reset"),
        java.net.SocketTimeoutException("read timed out"),
        java.net.UnknownHostException("unresolved host"),
        java.net.ProtocolException("HTTP transport"),
        java.io.InterruptedIOException("interrupted read"),
        java.io.EOFException("short body"),
        javax.net.ssl.SSLException("certificate handshake"),
    )
    for (error in transportErrors) {
        error.initCause(IllegalArgumentException("non-IO platform detail"))
        check(invocationNetworkFailure(java.io.IOException(error))) {
            "transport cause became replay-eligible source failure: ${error.javaClass.name}"
        }
    }
    check(invocationNetworkFailure(java.io.IOException("body read failed")))
    check(!invocationNetworkFailure(java.io.IOException(IllegalArgumentException("parse failed")))) {
        "UncaughtExceptionInterceptor parser wrapper must stay a source failure"
    }
    check(!invocationNetworkFailure(IllegalStateException("source model failed")))
    check(!invocationNetworkFailure(java.io.IOException(java.net.UnknownServiceException("unsupported protocol"))))
    println("Mihon nested transport errors preserve network retry; parser/protocol errors stay source: OK")
}
'''
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        runner = root / 'NetworkFailure.kt'
        runner.write_text(harness)
        output = root / 'network-failure.jar'
        subprocess.run([kotlinc, str(runner), '-include-runtime', '-d', str(output)], check=True)
        subprocess.run([java, '-jar', str(output)], check=True)


verify_host_network_failure_classification()
verify_host_replay_capabilities()
print('Mihon default NetworkHelper interceptor contract: OK')

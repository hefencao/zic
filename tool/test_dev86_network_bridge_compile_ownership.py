#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    path = ROOT / relative
    if not path.is_file():
        raise SystemExit(f'missing dev.86 contract file: {relative}')
    return path.read_text(encoding='utf-8')


def require(relative: str, *tokens: str) -> str:
    source = read(relative)
    for token in tokens:
        if token not in source:
            raise SystemExit(f'{relative} is missing dev.86 contract: {token}')
    return source


def forbid(relative: str, *tokens: str) -> None:
    source = read(relative)
    for token in tokens:
        if token in source:
            raise SystemExit(f'{relative} violates dev.86 ownership: {token}')


def main() -> int:
    for name in ('MihonLoginActivity', 'ExternalLoginSnapshotStore'):
        legacy = ROOT / f'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/{name}.kt'
        if legacy.exists():
            raise SystemExit(f'plugin_host_bridge retains obsolete browser ownership: {name}')
    require(
        'apps/app/lib/comic_details.dart',
        'typedef ComicDetailsSourceWebViewOpener = Future<void> Function({Uri? verificationUri});',
        'final ComicDetailsSourceWebViewOpener? onOpenSourceWebView;',
    )
    require(
        'apps/app/lib/home_shell_source_compat.dart',
        'builder: (_) => details.RemoteComicDetailsScreen(',
        'onOpenSourceWebView: ({Uri? verificationUri}) {',
    )
    require(
        'packages/network_bridge/lib/src/android_network_bridge.dart',
        "static const String _channelName = 'dev.zic/network_bridge';",
        'MethodChannel(_channelName)',
        "'openBrowser'",
        "'readBrowserSnapshot'",
        'final class NetworkBrowserSnapshot',
    )
    require(
        'packages/network_bridge/android/src/main/kotlin/dev/zic/network/NetworkBridgePlugin.kt',
        'class NetworkBridgePlugin',
        'NetworkBrowserActivity::class.java',
        'NetworkBrowserSnapshotStore.read(context, url)',
    )
    require(
        'packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/NetworkBrowserSnapshotStore.kt',
        'File(context.filesDir, FILE_NAME)',
        'File(target.parentFile, "$FILE_NAME.pending")',
        'pending.renameTo(target)',
    )
    forbid(
        'packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/NetworkBrowserSnapshotStore.kt',
        'getSharedPreferences',
    )
    forbid(
        'packages/network_bridge/android/src/main/AndroidManifest.xml',
        'android:process=',
    )
    forbid(
        'apps/app/android/app/build.gradle.kts',
        'zicNetworkBrowserProcess',
    )
    require(
        'packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/AndroidCloudflareInterceptor.kt',
        'class AndroidCloudflareInterceptor',
        'SourceVerificationRequiredException',
        'response.close()',
    )
    forbid(
        'packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/AndroidCloudflareInterceptor.kt',
        'WebView(',
        'CLOUDFLARE_WAIT_SECONDS',
    )
    require(
        'packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/AndroidCookieJar.kt',
        'class AndroidCookieJar(',
        'AndroidBrowserCookieSession.readCookies(',
        'memoryByHost',
        'CookieManager.getInstance()',
    )
    require(
        'packages/plugin_host_bridge/android/build.gradle',
        'networkRuntimeSources = file("../../network_bridge/android/src/runtime/kotlin")',
        'fileTree(networkRuntimeSources)',
    )
    require(
        'packages/network_bridge/android/build.gradle',
        'main.java.srcDir "src/runtime/kotlin"',
        'implementation "com.squareup.okhttp3:okhttp:5.4.0"',
        'consumerProguardFiles "consumer-rules.pro"',
    )
    forbid(
        'packages/network_bridge/android/build.gradle',
        'zicNetworkBrowserProcess',
    )
    require(
        'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt',
        'name.startsWith("dev.zic.network.")',
        '"dev.zic.network.AndroidCloudflareInterceptor"',
        '"dev.zic.network.AndroidCookieJar"',
        '"dev.zic.network.FallbackDns"',
    )
    for abi in ('mihonRuntime14', 'mihonRuntime16'):
        require(
            f'packages/plugin_host_bridge/android/src/{abi}/kotlin/eu/kanade/tachiyomi/network/RuntimeNetwork.kt',
            'import dev.zic.network.AndroidCloudflareInterceptor',
            'import dev.zic.network.AndroidCookieJar',
            'import dev.zic.network.FallbackDns',
            'AndroidCookieJar(context, ::defaultUserAgentProvider)',
        )
    plugin = 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/PluginHostBridgePlugin.kt'
    forbid(
        plugin,
        'openMihonLogin',
        'readExternalLoginSnapshot',
        'MihonLoginActivity',
        'ExternalLoginSnapshotStore',
    )
    forbid(
        'packages/plugin_host_bridge/lib/src/android_mihon_metadata_reader.dart',
        'ExternalLoginSnapshot',
        'openLogin(',
        'readLoginSnapshot(',
    )
    forbid(
        'packages/plugin_host_bridge/lib/src/external_plugin_controller.dart',
        'AndroidNetworkBridge',
        'openSourceWebView(',
        'readSourceWebViewSnapshot(',
    )
    require(
        'apps/app/lib/app_runtime.dart',
        "import 'package:network_bridge/network_bridge.dart';",
        'this.networkBridge = const AndroidNetworkBridge()',
        'final AndroidNetworkBridge networkBridge;',
        'networkBridge: widget.networkBridge',
    )
    require(
        'apps/app/lib/home_shell.dart',
        'final AndroidNetworkBridge networkBridge;',
        'networkBridge: widget.networkBridge',
    )
    require(
        'apps/app/lib/home_shell_source_compat.dart',
        'widget.networkBridge.openBrowser(',
    )
    require(
        'apps/app/lib/source_browser.dart',
        'final AndroidNetworkBridge networkBridge;',
        'networkBridge.openBrowser',
        'networkBridge.readBrowserSnapshot(url)',
    )
    require(
        'apps/app/pubspec.yaml',
        '  network_bridge:',
        '    path: ../../packages/network_bridge',
    )
    workspace = read('pubspec.yaml')
    if '  - packages/network_bridge' not in workspace:
        raise SystemExit('network_bridge is missing from the workspace')
    for runner in ('tool/analyze.sh', 'tool/test_flutter.sh'):
        if 'packages/network_bridge' not in read(runner):
            raise SystemExit(f'{runner} does not include network_bridge')
    print('dev.86 network bridge and compile ownership contract: OK')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

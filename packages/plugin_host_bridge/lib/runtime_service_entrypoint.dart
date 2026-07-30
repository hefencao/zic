import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:plugin_host/plugin_host.dart';

import 'src/native_runtime_drivers.dart';
import 'src/runtime_service_handler.dart';

/// Creates the Dart-owned endpoint inside the dedicated Android runtime
/// process and attaches it to the process-local MethodChannel.
///
/// Production installs process-local Android drivers for both supported
/// ecosystems. Payload verification, session ownership, cancellation and
/// shutdown policy remain in Dart; Kotlin only supplies the APIs that require
/// DexClassLoader or WebView inside the same dedicated process.
final class AndroidExternalPluginRuntimeServiceBootstrap {
  const AndroidExternalPluginRuntimeServiceBootstrap._();

  static Future<AndroidExternalPluginRuntimeServiceHandler> start({
    Iterable<ExternalPluginRuntimeDriverFactory> factories =
        const <ExternalPluginRuntimeDriverFactory>[],
    ExternalPluginRuntimePayloadVerifier? payloadVerifier,
    Directory? verifiedDirectory,
    String? processId,
    MethodChannel channel = const MethodChannel(
      AndroidExternalPluginRuntimeServiceHandler.defaultChannelName,
    ),
  }) async {
    WidgetsFlutterBinding.ensureInitialized();
    final verifier = payloadVerifier ??
        FileExternalPluginRuntimePayloadVerifier(
          verifiedDirectory: verifiedDirectory,
        );
    final endpoint = ExternalPluginRuntimeServiceEndpoint(
      processHost: ExternalPluginRuntimeProcessHost(
        factories: factories,
        payloadVerifier: verifier,
      ),
      processId: processId,
    );
    final handler = AndroidExternalPluginRuntimeServiceHandler(
      endpoint: endpoint,
      channel: channel,
    );
    handler.attach();
    try {
      await channel.invokeMethod<void>(
        'runtimeServiceReady',
        <String, Object?>{'processId': endpoint.processId},
      );
      return handler;
    } on Object {
      await handler.detach();
      rethrow;
    }
  }
}

AndroidExternalPluginRuntimeServiceHandler? _runtimeServiceHandler;

/// FlutterEngine entrypoint used only by the non-exported Android service
/// process declared by `plugin_host_bridge`.
@pragma('vm:entry-point')
Future<void> zicExternalPluginRuntimeServiceMain() async {
  _runtimeServiceHandler =
      await AndroidExternalPluginRuntimeServiceBootstrap.start(
    factories: <ExternalPluginRuntimeDriverFactory>[
      AndroidNativeExternalPluginRuntimeDriverFactory(
        format: ExternalComicPluginFormat.mihonExtension,
      ),
      AndroidNativeExternalPluginRuntimeDriverFactory(
        format: ExternalComicPluginFormat.veneraJavaScript,
      ),
    ],
  );
}

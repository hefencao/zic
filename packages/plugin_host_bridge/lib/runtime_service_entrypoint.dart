import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:plugin_host/plugin_host.dart';

import 'src/runtime_service_handler.dart';

/// Creates the Dart-owned endpoint inside the dedicated Android runtime
/// process and attaches it to the process-local MethodChannel.
///
/// Production currently supplies no ecosystem drivers, so activation remains
/// fail-closed with `driver-unavailable`. Concrete Mihon and Venera drivers can
/// be installed here later without moving payload verification, session
/// ownership, cancellation, or shutdown policy into Kotlin.
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
      await AndroidExternalPluginRuntimeServiceBootstrap.start();
}

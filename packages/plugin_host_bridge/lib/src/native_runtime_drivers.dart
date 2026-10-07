import 'dart:async';

import 'package:flutter/services.dart';
import 'package:plugin_host/plugin_host.dart';

import 'method_channel_runtime_backends.dart';

/// Process-local bridge from the Dart runtime owner to ecosystem drivers that
/// require Android APIs (DexClassLoader for Mihon, WebView for Venera).
///
/// This channel never crosses Binder. The surrounding FlutterEngine and the
/// native drivers live in the same dedicated `:zic_plugin_runtime` process.
abstract final class NativeExternalPluginRuntimeMethods {
  static const String create = 'createNativeExternalPluginDriver';
  static const String invoke = 'invokeNativeExternalPluginDriver';
  static const String cancel = 'cancelNativeExternalPluginDriver';
  static const String close = 'closeNativeExternalPluginDriver';
}

final class AndroidNativeExternalPluginRuntimeDriverFactory
    implements ExternalPluginRuntimeDriverFactory {
  AndroidNativeExternalPluginRuntimeDriverFactory({
    required this.format,
    MethodChannel channel = const MethodChannel(_channelName),
    this.support = const PlatformExternalPluginRuntimeSupport(),
  }) : _channel = channel;

  static const String _channelName = 'dev.zic/plugin_host_runtime_bridge';

  @override
  final ExternalComicPluginFormat format;
  final MethodChannel _channel;
  final PlatformExternalPluginRuntimeSupport support;

  @override
  bool supportsLimits(ExternalPluginRuntimeLimits limits) =>
      support.supports(limits);

  @override
  Future<ExternalPluginRuntimeDriver> create(
    ExternalPluginRuntimeActivationEnvelope activation,
    ExternalPluginRuntimeVerifiedPayload payload,
  ) async {
    if (activation.format != format) {
      throw const ExternalPluginRuntimeProcessException(
        code: 'runtime-format-mismatch',
        message: 'native runtime factory received another ecosystem format',
      );
    }
    final result = await _channel.invokeMapMethod<String, Object?>(
      NativeExternalPluginRuntimeMethods.create,
      <String, Object?>{
        'format': format.name,
        'activation': _nativeActivationMessage(activation),
        'payloadPath': payload.path,
        'payloadByteLength': payload.byteLength,
        'payloadSha256': payload.sha256,
      },
    );
    if (result == null) {
      throw const ExternalPluginRuntimeProcessException(
        code: 'native-driver-invalid',
        message: 'native runtime driver activation returned no result',
      );
    }
    final driverId = result['driverId'];
    final runtimeId = result['runtimeId'];
    final rawSources = result['sources'];
    if (driverId is! String ||
        driverId.trim().isEmpty ||
        runtimeId is! String ||
        runtimeId.trim().isEmpty ||
        rawSources is! List<Object?>) {
      throw const ExternalPluginRuntimeProcessException(
        code: 'native-driver-invalid',
        message: 'native runtime driver activation result is invalid',
      );
    }
    final sources = rawSources
        .map(ExternalPluginRuntimeSourceDescriptor.fromMessage)
        .toList(growable: false);
    if (sources.isEmpty) {
      await _bestEffortClose(_channel, driverId);
      throw const ExternalPluginRuntimeProcessException(
        code: 'source-discovery-empty',
        message: 'native runtime exposed no comic sources',
      );
    }
    return _AndroidNativeExternalPluginRuntimeDriver(
      channel: _channel,
      driverId: driverId,
      runtimeId: runtimeId,
      sources: sources,
    );
  }
}

final class _AndroidNativeExternalPluginRuntimeDriver
    implements ExternalPluginRuntimeDriver, BodyExternalPluginRuntimeDriver {
  _AndroidNativeExternalPluginRuntimeDriver({
    required MethodChannel channel,
    required this.driverId,
    required this.runtimeId,
    required List<ExternalPluginRuntimeSourceDescriptor> sources,
  })  : _channel = channel,
        sources = List<ExternalPluginRuntimeSourceDescriptor>.unmodifiable(
          sources,
        );

  final MethodChannel _channel;
  final String driverId;

  @override
  final String runtimeId;

  @override
  final List<ExternalPluginRuntimeSourceDescriptor> sources;

  bool _closing = false;
  Future<void>? _closeFuture;

  @override
  Future<Object> invoke(
    ExternalPluginRuntimeRequest request,
    ExternalPluginRuntimeCancellationToken cancellation,
  ) async {
    if (_closing) {
      throw ExternalPluginRuntimeDriverException(
        code: 'runtime-closing',
        message: 'native runtime driver is closing',
      );
    }
    cancellation.throwIfCancelled();
    var completed = false;
    Object? receivedPayload;
    unawaited(
      cancellation.whenCancelled.then((_) async {
        if (completed || _closing) {
          return;
        }
        try {
          await _channel.invokeMethod<void>(
            NativeExternalPluginRuntimeMethods.cancel,
            <String, Object?>{
              'driverId': driverId,
              'requestId': request.requestId,
            },
          );
        } on Object {
          // The worker still waits for the real invocation Future. A failed
          // best-effort native cancellation must not release its permit early.
        }
      }),
    );
    try {
      final value = await _channel.invokeMethod<Object?>(
        NativeExternalPluginRuntimeMethods.invoke,
        <String, Object?>{
          'driverId': driverId,
          'request': request.toMessage(),
        },
      );
      receivedPayload = value;
      cancellation.throwIfCancelled();
      if (value == null) {
        throw ExternalPluginRuntimeDriverException(
          code: 'native-result-empty',
          message: 'native runtime returned no protocol payload',
        );
      }
      return value;
    } on PlatformException catch (error) {
      final details = <String, Object?>{};
      final rawDetails = error.details;
      if (rawDetails is Map<Object?, Object?>) {
        for (final entry in rawDetails.entries) {
          if (entry.key is String && _isWireScalar(entry.value)) {
            details[entry.key as String] = entry.value;
          }
        }
      }
      throw ExternalPluginRuntimeDriverException(
        code: error.code,
        message: error.message ?? 'native plugin runtime operation failed',
        retryable: details['retryable'] == true,
        details: details,
      );
    } finally {
      completed = true;
      if (cancellation.isCancelled &&
          ExternalPluginRuntimeBodyFile.isBodyFile(receivedPayload)) {
        await discardResourceBody(
          ExternalPluginRuntimeBodyFile.fromMessage(receivedPayload),
        );
      }
    }
  }

  @override
  Future<void> discardResourceBody(ExternalPluginRuntimeBodyFile reference) =>
      _channel.invokeMethod<void>(
        'discardExternalRuntimeResourceBody', reference.toMessage(),
      );

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    await _channel.invokeMethod<void>(
      NativeExternalPluginRuntimeMethods.close,
      <String, Object?>{'driverId': driverId},
    );
  }
}

Map<String, Object?> _nativeActivationMessage(
  ExternalPluginRuntimeActivationEnvelope activation,
) {
  final common = <String, Object?>{
    'pluginId': activation.pluginId,
    'pluginVersion': activation.pluginVersion,
    'capabilities': activation.capabilities.map((value) => value.name).toList(),
    'limits': activation.limits.toMessage(),
  };
  return switch (activation) {
    MihonRuntimeActivationEnvelope value => <String, Object?>{
        ...common,
        'packageName': value.packageName,
        'versionCode': value.versionCode,
        'extensionLib': value.extensionLib,
        'entryClasses': value.entryClasses,
      },
    VeneraRuntimeActivationEnvelope value => <String, Object?>{
        ...common,
        'sourceKey': value.sourceKey,
      },
  };
}

bool _isWireScalar(Object? value) =>
    value == null || value is bool || value is num || value is String;

Future<void> _bestEffortClose(MethodChannel channel, String driverId) async {
  try {
    await channel.invokeMethod<void>(
      NativeExternalPluginRuntimeMethods.close,
      <String, Object?>{'driverId': driverId},
    );
  } on Object {
    // Preserve the activation failure.
  }
}

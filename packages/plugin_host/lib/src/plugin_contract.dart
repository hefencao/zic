import 'package:catalog/catalog.dart';

enum ExternalPluginCapability {
  network,
  cookies,
  persistentStorage,
  credentials,
  webView,
  nativeCode,
}

enum ExternalPluginDenial {
  formatMismatch,
  insecureEntrypoint,
  untrustedRepository,
  quarantined,
  adultContentDenied,
  payloadNotTrusted,
  packageMismatch,
  signerNotTrusted,
  versionMismatch,
  versionRollback,
  unsupportedAbi,
  capabilityDenied,
  sourceIdentityMismatch,
  sourceIdentityCollision,
  hostUnavailable,
  inspectionFailed,
  activationFailed,
  runtimeMetadataMissing,
}

final class ExternalPluginInspection {
  ExternalPluginInspection({
    required this.format,
    required this.payloadSha256,
    Iterable<ExternalPluginCapability> requestedCapabilities =
        const <ExternalPluginCapability>{},
    this.payloadPath,
    this.payloadByteLength,
    this.packageName,
    this.signerSha256,
    this.versionCode,
    this.extensionLib,
    Iterable<String> mihonEntryClasses = const <String>[],
    this.sourceKey,
  })  : requestedCapabilities =
            Set<ExternalPluginCapability>.unmodifiable(requestedCapabilities),
        mihonEntryClasses = List<String>.unmodifiable(mihonEntryClasses) {
    if (payloadSha256.trim().isEmpty) {
      throw ArgumentError.value(
        payloadSha256,
        'payloadSha256',
        'must not be empty',
      );
    }
    if ((payloadPath == null) != (payloadByteLength == null) ||
        (payloadPath != null && payloadPath!.trim().isEmpty) ||
        (payloadByteLength != null && payloadByteLength! < 0)) {
      throw ArgumentError(
        'payloadPath and payloadByteLength must describe one valid file',
      );
    }
  }

  final ExternalComicPluginFormat format;
  final String payloadSha256;
  final Set<ExternalPluginCapability> requestedCapabilities;

  /// Stable immutable payload acquired by the inspector. Executors may open
  /// this exact file after policy approval instead of downloading it again.
  final String? payloadPath;
  final int? payloadByteLength;

  /// Mihon-compatible APK metadata obtained before class loading.
  final String? packageName;
  final String? signerSha256;
  final int? versionCode;
  final String? extensionLib;
  final List<String> mihonEntryClasses;

  /// Venera-compatible source key obtained from repository metadata or a
  /// constrained metadata-only script inspection.
  final String? sourceKey;
}

abstract interface class ExternalPluginInspector {
  ExternalComicPluginFormat get format;

  Future<ExternalPluginInspection> inspect(
    ExternalComicPluginCatalogEntry plugin,
  );
}

abstract interface class ExternalPluginExecutor {
  ExternalComicPluginFormat get format;

  Future<ExternalComicPluginSession> activate(
    ExternalComicPluginCatalogEntry plugin,
    ExternalPluginInspection inspection,
  );
}

final class ExternalPluginActivationException implements Exception {
  ExternalPluginActivationException({
    required this.pluginId,
    required Iterable<ExternalPluginDenial> denials,
    this.cause,
  }) : denials = Set<ExternalPluginDenial>.unmodifiable(denials);

  final String pluginId;
  final Set<ExternalPluginDenial> denials;
  final Object? cause;

  @override
  String toString() =>
      'ExternalPluginActivationException($pluginId, '
      '${denials.map((value) => value.name).join(', ')})';
}

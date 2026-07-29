import 'package:catalog/catalog.dart';

import 'plugin_contract.dart';

/// Resource envelope that every ecosystem-specific runtime must enforce.
///
/// The pure-Dart gate cannot enforce native heap or JavaScript CPU limits by
/// itself. It passes these limits to the isolated backend, which must reject an
/// invocation it cannot bound rather than silently running unrestricted code.
final class ExternalPluginRuntimeLimits {
  const ExternalPluginRuntimeLimits({
    this.invocationTimeout = const Duration(seconds: 15),
    this.maxResponseBytes = 16 * 1024 * 1024,
    this.maxConcurrentInvocations = 4,
    this.maxRuntimeHeapBytes = 64 * 1024 * 1024,
  })  : assert(invocationTimeout > Duration.zero),
        assert(maxResponseBytes > 0),
        assert(maxConcurrentInvocations > 0),
        assert(maxRuntimeHeapBytes > 0);

  final Duration invocationTimeout;
  final int maxResponseBytes;
  final int maxConcurrentInvocations;
  final int maxRuntimeHeapBytes;
}

final class MihonExecutionRequest {
  MihonExecutionRequest({
    required this.plugin,
    required this.payloadPath,
    required this.payloadByteLength,
    required this.payloadSha256,
    required this.packageName,
    required this.signerSha256,
    required this.versionCode,
    required this.extensionLib,
    required Iterable<String> entryClasses,
    required Iterable<ExternalPluginCapability> capabilities,
    required this.limits,
  })  : entryClasses = List<String>.unmodifiable(entryClasses),
        capabilities =
            Set<ExternalPluginCapability>.unmodifiable(capabilities);

  final ExternalComicPluginCatalogEntry plugin;
  final String payloadPath;
  final int payloadByteLength;
  final String payloadSha256;
  final String packageName;
  final String signerSha256;
  final int versionCode;
  final String extensionLib;
  final List<String> entryClasses;
  final Set<ExternalPluginCapability> capabilities;
  final ExternalPluginRuntimeLimits limits;
}

/// Android implementation must isolate class loading from the app class path
/// and may load only the exact payload described by [MihonExecutionRequest].
abstract interface class MihonIsolatedRuntimeBackend {
  bool supportsLimits(ExternalPluginRuntimeLimits limits);

  Future<ExternalComicPluginSession> activate(MihonExecutionRequest request);
}

final class MihonIsolatedExecutor implements ExternalPluginExecutor {
  const MihonIsolatedExecutor({
    required this.backend,
    this.limits = const ExternalPluginRuntimeLimits(),
  });

  final MihonIsolatedRuntimeBackend backend;
  final ExternalPluginRuntimeLimits limits;

  @override
  ExternalComicPluginFormat get format =>
      ExternalComicPluginFormat.mihonExtension;

  @override
  Future<ExternalComicPluginSession> activate(
    ExternalComicPluginCatalogEntry plugin,
    ExternalPluginInspection inspection,
  ) {
    final path = inspection.payloadPath;
    final length = inspection.payloadByteLength;
    final packageName = inspection.packageName;
    final signer = inspection.signerSha256;
    final version = inspection.versionCode;
    final extensionLib = inspection.extensionLib;
    final classes = inspection.mihonEntryClasses;
    if (plugin.format != format ||
        inspection.format != format ||
        path == null ||
        path.trim().isEmpty ||
        length == null ||
        length <= 0 ||
        packageName == null ||
        packageName.trim().isEmpty ||
        signer == null ||
        signer.trim().isEmpty ||
        version == null ||
        version < 0 ||
        extensionLib == null ||
        extensionLib.trim().isEmpty ||
        classes.isEmpty ||
        classes.any((value) => value.trim().isEmpty)) {
      throw StateError('trusted Mihon inspection is incomplete');
    }
    if (!backend.supportsLimits(limits)) {
      throw StateError('Mihon runtime cannot enforce requested limits');
    }
    return backend.activate(
      MihonExecutionRequest(
        plugin: plugin,
        payloadPath: path,
        payloadByteLength: length,
        payloadSha256: inspection.payloadSha256,
        packageName: packageName,
        signerSha256: signer,
        versionCode: version,
        extensionLib: extensionLib,
        entryClasses: classes,
        capabilities: inspection.requestedCapabilities,
        limits: limits,
      ),
    );
  }
}

final class VeneraExecutionRequest {
  VeneraExecutionRequest({
    required this.plugin,
    required this.payloadPath,
    required this.payloadByteLength,
    required this.payloadSha256,
    required this.sourceKey,
    required Iterable<ExternalPluginCapability> capabilities,
    required this.limits,
  }) : capabilities =
            Set<ExternalPluginCapability>.unmodifiable(capabilities);

  final ExternalComicPluginCatalogEntry plugin;
  final String payloadPath;
  final int payloadByteLength;
  final String payloadSha256;
  final String sourceKey;
  final Set<ExternalPluginCapability> capabilities;
  final ExternalPluginRuntimeLimits limits;
}

/// Backend for a bounded JavaScript runtime. Network, cookie and storage access
/// must be provided only through explicit host bridges approved by policy.
abstract interface class VeneraSandboxRuntimeBackend {
  bool supportsLimits(ExternalPluginRuntimeLimits limits);

  Future<ExternalComicPluginSession> activate(VeneraExecutionRequest request);
}

final class VeneraSandboxExecutor implements ExternalPluginExecutor {
  const VeneraSandboxExecutor({
    required this.backend,
    this.limits = const ExternalPluginRuntimeLimits(
      invocationTimeout: Duration(seconds: 10),
      maxResponseBytes: 8 * 1024 * 1024,
      maxConcurrentInvocations: 2,
      maxRuntimeHeapBytes: 32 * 1024 * 1024,
    ),
  });

  final VeneraSandboxRuntimeBackend backend;
  final ExternalPluginRuntimeLimits limits;

  @override
  ExternalComicPluginFormat get format =>
      ExternalComicPluginFormat.veneraJavaScript;

  @override
  Future<ExternalComicPluginSession> activate(
    ExternalComicPluginCatalogEntry plugin,
    ExternalPluginInspection inspection,
  ) {
    final path = inspection.payloadPath;
    final length = inspection.payloadByteLength;
    final sourceKey = inspection.sourceKey;
    if (plugin.format != format ||
        inspection.format != format ||
        path == null ||
        path.trim().isEmpty ||
        length == null ||
        length <= 0 ||
        sourceKey == null ||
        sourceKey.trim().isEmpty) {
      throw StateError('trusted Venera inspection is incomplete');
    }
    if (!backend.supportsLimits(limits)) {
      throw StateError('Venera runtime cannot enforce requested limits');
    }
    return backend.activate(
      VeneraExecutionRequest(
        plugin: plugin,
        payloadPath: path,
        payloadByteLength: length,
        payloadSha256: inspection.payloadSha256,
        sourceKey: sourceKey,
        capabilities: inspection.requestedCapabilities,
        limits: limits,
      ),
    );
  }
}

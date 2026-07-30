import 'package:catalog/catalog.dart';

import 'plugin_contract.dart';
import 'runtime_limits.dart';
import 'runtime_protocol.dart';
import 'runtime_source_adapter.dart';

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
            Set<ExternalPluginCapability>.unmodifiable(capabilities) {
    if (plugin.format != ExternalComicPluginFormat.mihonExtension ||
        payloadPath.trim().isEmpty ||
        payloadByteLength <= 0 ||
        payloadSha256.trim().isEmpty ||
        packageName.trim().isEmpty ||
        signerSha256.trim().isEmpty ||
        versionCode < 0 ||
        extensionLib.trim().isEmpty ||
        this.entryClasses.isEmpty ||
        this.entryClasses.any((value) => value.trim().isEmpty)) {
      throw ArgumentError('Mihon execution request is incomplete');
    }
    limits.validate();
  }

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

  Map<String, Object?> toMessage() {
    final capabilityNames = capabilities.map((value) => value.name).toList()
      ..sort();
    return <String, Object?>{
      'schemaVersion': 1,
      'format': plugin.format.name,
      'pluginId': plugin.pluginId,
      'pluginVersion': plugin.version,
      'payloadPath': payloadPath,
      'payloadByteLength': payloadByteLength,
      'payloadSha256': payloadSha256,
      'packageName': packageName,
      'signerSha256': signerSha256,
      'versionCode': versionCode,
      'extensionLib': extensionLib,
      'entryClasses': entryClasses,
      'capabilities': capabilityNames,
      'limits': limits.toMessage(),
    };
  }
}

/// Android implementation must isolate class loading from the app class path
/// and may load only the exact payload described by [MihonExecutionRequest].
abstract interface class MihonIsolatedRuntimeBackend {
  bool supportsLimits(ExternalPluginRuntimeLimits limits);

  Future<ExternalPluginRuntimeConnection> activate(
    MihonExecutionRequest request,
  );
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
  ) async {
    limits.validate();
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
    final connection = await backend.activate(
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
    try {
      return ExternalPluginRuntimeSession(
        plugin: plugin,
        connection: connection,
        limits: limits,
      );
    } on Object {
      await connection.close();
      rethrow;
    }
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
            Set<ExternalPluginCapability>.unmodifiable(capabilities) {
    if (plugin.format != ExternalComicPluginFormat.veneraJavaScript ||
        payloadPath.trim().isEmpty ||
        payloadByteLength <= 0 ||
        payloadSha256.trim().isEmpty ||
        sourceKey.trim().isEmpty) {
      throw ArgumentError('Venera execution request is incomplete');
    }
    limits.validate();
  }

  final ExternalComicPluginCatalogEntry plugin;
  final String payloadPath;
  final int payloadByteLength;
  final String payloadSha256;
  final String sourceKey;
  final Set<ExternalPluginCapability> capabilities;
  final ExternalPluginRuntimeLimits limits;

  Map<String, Object?> toMessage() {
    final capabilityNames = capabilities.map((value) => value.name).toList()
      ..sort();
    return <String, Object?>{
      'schemaVersion': 1,
      'format': plugin.format.name,
      'pluginId': plugin.pluginId,
      'pluginVersion': plugin.version,
      'payloadPath': payloadPath,
      'payloadByteLength': payloadByteLength,
      'payloadSha256': payloadSha256,
      'sourceKey': sourceKey,
      'capabilities': capabilityNames,
      'limits': limits.toMessage(),
    };
  }
}

/// Backend for a bounded JavaScript runtime. Network, cookie and storage access
/// must be provided only through explicit host bridges approved by policy.
abstract interface class VeneraSandboxRuntimeBackend {
  bool supportsLimits(ExternalPluginRuntimeLimits limits);

  Future<ExternalPluginRuntimeConnection> activate(
    VeneraExecutionRequest request,
  );
}

final class VeneraSandboxExecutor implements ExternalPluginExecutor {
  const VeneraSandboxExecutor({
    required this.backend,
    this.limits = const ExternalPluginRuntimeLimits(
      invocationTimeout: Duration(seconds: 15),
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
  ) async {
    limits.validate();
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
    final connection = await backend.activate(
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
    try {
      return ExternalPluginRuntimeSession(
        plugin: plugin,
        connection: connection,
        limits: limits,
      );
    } on Object {
      await connection.close();
      rethrow;
    }
  }
}

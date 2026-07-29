import 'dart:convert';
import 'dart:io';

import 'package:catalog/catalog.dart';
import 'package:crypto/crypto.dart';

import 'plugin_contract.dart';

/// Stable local copy of an external plugin payload.
///
/// The loader owns download, atomic promotion and retention. Inspectors only
/// stream the immutable file; they never execute APK or JavaScript code.
final class ExternalPluginPayloadFile {
  const ExternalPluginPayloadFile({
    required this.path,
    required this.byteLength,
  })  : assert(path != ''),
        assert(byteLength >= 0);

  final String path;
  final int byteLength;
}

abstract interface class ExternalPluginPayloadLoader {
  Future<ExternalPluginPayloadFile> acquire(
    ExternalComicPluginCatalogEntry plugin,
  );
}

final class CallbackExternalPluginPayloadLoader
    implements ExternalPluginPayloadLoader {
  const CallbackExternalPluginPayloadLoader(this.callback);

  final Future<ExternalPluginPayloadFile> Function(
    ExternalComicPluginCatalogEntry plugin,
  ) callback;

  @override
  Future<ExternalPluginPayloadFile> acquire(
    ExternalComicPluginCatalogEntry plugin,
  ) =>
      callback(plugin);
}

final class MihonApkMetadata {
  const MihonApkMetadata({
    required this.packageName,
    required this.signerSha256,
    required this.versionCode,
    required this.extensionLib,
  });

  final String packageName;
  final String signerSha256;
  final int versionCode;
  final String extensionLib;
}

/// Android-specific metadata adapter.
///
/// Implementations may use PackageManager or a dedicated APK parser, but must
/// not create a class loader or initialize extension classes during inspection.
abstract interface class MihonApkMetadataReader {
  Future<MihonApkMetadata> readMetadata(String apkPath);
}

final class MihonApkInspector implements ExternalPluginInspector {
  const MihonApkInspector({
    required this.payloads,
    required this.metadata,
    this.maxPayloadBytes = 128 * 1024 * 1024,
  }) : assert(maxPayloadBytes > 0);

  final ExternalPluginPayloadLoader payloads;
  final MihonApkMetadataReader metadata;
  final int maxPayloadBytes;

  @override
  ExternalComicPluginFormat get format =>
      ExternalComicPluginFormat.mihonExtension;

  @override
  Future<ExternalPluginInspection> inspect(
    ExternalComicPluginCatalogEntry plugin,
  ) async {
    _requireFormat(plugin, format);
    final payload = await payloads.acquire(plugin);
    await _validatePayload(payload, maxPayloadBytes);
    final apk = await metadata.readMetadata(payload.path);
    return ExternalPluginInspection(
      format: format,
      payloadSha256: await _sha256File(payload),
      payloadPath: payload.path,
      payloadByteLength: payload.byteLength,
      packageName: apk.packageName,
      signerSha256: apk.signerSha256,
      versionCode: apk.versionCode,
      extensionLib: apk.extensionLib,
      requestedCapabilities: const <ExternalPluginCapability>{
        ExternalPluginCapability.network,
        ExternalPluginCapability.cookies,
        ExternalPluginCapability.persistentStorage,
        ExternalPluginCapability.credentials,
        ExternalPluginCapability.webView,
        ExternalPluginCapability.nativeCode,
      },
    );
  }
}

final class VeneraJavaScriptInspector implements ExternalPluginInspector {
  const VeneraJavaScriptInspector({
    required this.payloads,
    this.maxPayloadBytes = 4 * 1024 * 1024,
    this.requestedCapabilities = const <ExternalPluginCapability>{
      ExternalPluginCapability.network,
      ExternalPluginCapability.cookies,
      ExternalPluginCapability.persistentStorage,
    },
  }) : assert(maxPayloadBytes > 0);

  final ExternalPluginPayloadLoader payloads;
  final int maxPayloadBytes;
  final Set<ExternalPluginCapability> requestedCapabilities;

  @override
  ExternalComicPluginFormat get format =>
      ExternalComicPluginFormat.veneraJavaScript;

  @override
  Future<ExternalPluginInspection> inspect(
    ExternalComicPluginCatalogEntry plugin,
  ) async {
    _requireFormat(plugin, format);
    final payload = await payloads.acquire(plugin);
    final veneraPayload = await _readVeneraPayload(payload, maxPayloadBytes);
    final script = veneraPayload.script;
    final declaredKeys = plugin.sources
        .map((source) => source.externalId.trim())
        .where((value) => value.isNotEmpty)
        .toSet();
    final lexicalKeys = _veneraKeys(script);
    if (lexicalKeys.length > 1) {
      throw const FormatException(
        'Venera script declares conflicting source keys',
      );
    }
    final lexicalKey = lexicalKeys.firstOrNull;
    if (declaredKeys.isNotEmpty &&
        lexicalKey != null &&
        !declaredKeys.contains(lexicalKey)) {
      throw const FormatException(
        'Venera repository key does not match script metadata',
      );
    }
    final sourceKey = declaredKeys.length == 1
        ? declaredKeys.single
        : lexicalKey;
    return ExternalPluginInspection(
      format: format,
      payloadSha256: veneraPayload.sha256,
      payloadPath: payload.path,
      payloadByteLength: payload.byteLength,
      sourceKey: sourceKey,
      requestedCapabilities: requestedCapabilities,
    );
  }
}

final class _VeneraPayload {
  const _VeneraPayload({
    required this.script,
    required this.sha256,
  });

  final String script;
  final String sha256;
}

Future<_VeneraPayload> _readVeneraPayload(
  ExternalPluginPayloadFile payload,
  int maxBytes,
) async {
  final file = File(payload.path);
  final actualLength = await file.length();
  if (actualLength != payload.byteLength) {
    throw const FormatException('external plugin payload length changed');
  }
  if (actualLength > maxBytes) {
    throw FormatException(
      'external plugin payload exceeds limit: $actualLength > $maxBytes',
    );
  }
  final bytes = await file.readAsBytes();
  if (bytes.lengthInBytes != actualLength) {
    throw const FormatException('external plugin payload changed while reading');
  }
  return _VeneraPayload(
    script: utf8.decode(bytes),
    sha256: sha256.convert(bytes).toString(),
  );
}

void _requireFormat(
  ExternalComicPluginCatalogEntry plugin,
  ExternalComicPluginFormat expected,
) {
  if (plugin.format != expected) {
    throw ArgumentError.value(plugin.format, 'plugin.format');
  }
  if (plugin.entrypoint.scheme != 'https' &&
      plugin.entrypoint.scheme != 'http') {
    throw const FormatException('external plugin entrypoint is not network-safe');
  }
}

Future<void> _validatePayload(
  ExternalPluginPayloadFile payload,
  int maxBytes,
) async {
  final actualLength = await File(payload.path).length();
  if (actualLength != payload.byteLength) {
    throw const FormatException('external plugin payload length changed');
  }
  if (actualLength > maxBytes) {
    throw FormatException(
      'external plugin payload exceeds limit: $actualLength > $maxBytes',
    );
  }
}

Future<String> _sha256File(ExternalPluginPayloadFile payload) async {
  final file = File(payload.path);
  final actualLength = await file.length();
  if (actualLength != payload.byteLength) {
    throw const FormatException('external plugin payload length changed');
  }
  return (await sha256.bind(file.openRead()).first).toString();
}

Set<String> _veneraKeys(String script) {
  final matches = RegExp(
    "(?:^|\\s|,|;|\\x7b)key\\s*[:=]\\s*[\"']([^\"']+)[\"']",
    multiLine: true,
  ).allMatches(script);
  return <String>{
    for (final match in matches)
      if ((match.group(1)?.trim() ?? '').isNotEmpty) match.group(1)!.trim(),
  };
}

extension<T> on Set<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

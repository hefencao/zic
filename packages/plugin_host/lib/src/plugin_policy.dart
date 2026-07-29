import 'package:catalog/catalog.dart';

import 'plugin_contract.dart';

abstract interface class ExternalPluginQuarantine {
  String? reasonFor(String pluginId);

  void quarantine(String pluginId, String reason);

  void clear(String pluginId);
}

final class MemoryExternalPluginQuarantine implements ExternalPluginQuarantine {
  final Map<String, String> _reasons = <String, String>{};

  @override
  String? reasonFor(String pluginId) => _reasons[pluginId];

  @override
  void quarantine(String pluginId, String reason) {
    _reasons[pluginId] = reason;
  }

  @override
  void clear(String pluginId) {
    _reasons.remove(pluginId);
  }
}

final class ExternalPluginGateDecision {
  ExternalPluginGateDecision({
    required Iterable<ExternalPluginDenial> denials,
    this.quarantineReason,
  }) : denials = Set<ExternalPluginDenial>.unmodifiable(denials);

  final Set<ExternalPluginDenial> denials;
  final String? quarantineReason;

  bool get allowed => denials.isEmpty;
}

final class ExternalPluginTrustPolicy {
  ExternalPluginTrustPolicy({
    Iterable<String> trustedRepositoryOrigins = const <String>{},
    Iterable<String> trustedPayloadSha256 = const <String>{},
    Iterable<String> trustedMihonSignerSha256 = const <String>{},
    Iterable<String> allowedMihonExtensionLibs = const <String>{},
    Iterable<ExternalPluginCapability> allowedMihonCapabilities =
        const <ExternalPluginCapability>{
      ExternalPluginCapability.network,
      ExternalPluginCapability.cookies,
      ExternalPluginCapability.persistentStorage,
      ExternalPluginCapability.credentials,
      ExternalPluginCapability.webView,
      ExternalPluginCapability.nativeCode,
    },
    Iterable<ExternalPluginCapability> allowedVeneraCapabilities =
        const <ExternalPluginCapability>{
      ExternalPluginCapability.network,
    },
    Map<String, int> minimumVersionCodes = const <String, int>{},
    this.allowAdult = false,
    this.requireHttps = true,
    this.requireTrustedRepository = true,
    this.requireTrustedPayload = true,
  })  : trustedRepositoryOrigins = Set<String>.unmodifiable(
          trustedRepositoryOrigins.map(_normalizeOrigin),
        ),
        trustedPayloadSha256 = Set<String>.unmodifiable(
          trustedPayloadSha256.map(_normalizeDigest),
        ),
        trustedMihonSignerSha256 = Set<String>.unmodifiable(
          trustedMihonSignerSha256.map(_normalizeDigest),
        ),
        allowedMihonExtensionLibs =
            Set<String>.unmodifiable(allowedMihonExtensionLibs),
        allowedMihonCapabilities =
            Set<ExternalPluginCapability>.unmodifiable(
          allowedMihonCapabilities,
        ),
        allowedVeneraCapabilities =
            Set<ExternalPluginCapability>.unmodifiable(
          allowedVeneraCapabilities,
        ),
        minimumVersionCodes = Map<String, int>.unmodifiable(
          minimumVersionCodes,
        );

  final Set<String> trustedRepositoryOrigins;
  final Set<String> trustedPayloadSha256;
  final Set<String> trustedMihonSignerSha256;
  final Set<String> allowedMihonExtensionLibs;
  final Set<ExternalPluginCapability> allowedMihonCapabilities;
  final Set<ExternalPluginCapability> allowedVeneraCapabilities;
  final Map<String, int> minimumVersionCodes;
  final bool allowAdult;
  final bool requireHttps;
  final bool requireTrustedRepository;
  final bool requireTrustedPayload;

  ExternalPluginGateDecision evaluate({
    required ExternalComicPluginCatalogEntry plugin,
    required ExternalPluginInspection inspection,
    String? quarantineReason,
  }) {
    final denials = <ExternalPluginDenial>{};
    if (inspection.format != plugin.format) {
      denials.add(ExternalPluginDenial.formatMismatch);
    }
    if (requireHttps && plugin.entrypoint.scheme != 'https') {
      denials.add(ExternalPluginDenial.insecureEntrypoint);
    }
    if (requireTrustedRepository &&
        (trustedRepositoryOrigins.isEmpty ||
            !trustedRepositoryOrigins.contains(_origin(plugin.entrypoint)))) {
      denials.add(ExternalPluginDenial.untrustedRepository);
    }
    if (quarantineReason != null) {
      denials.add(ExternalPluginDenial.quarantined);
    }
    if (plugin.adult && !allowAdult) {
      denials.add(ExternalPluginDenial.adultContentDenied);
    }
    if (requireTrustedPayload &&
        (trustedPayloadSha256.isEmpty ||
            !trustedPayloadSha256.contains(
              _normalizeDigest(inspection.payloadSha256),
            ))) {
      denials.add(ExternalPluginDenial.payloadNotTrusted);
    }

    switch (plugin.format) {
      case ExternalComicPluginFormat.mihonExtension:
        _evaluateMihon(plugin, inspection, denials);
        break;
      case ExternalComicPluginFormat.veneraJavaScript:
        _evaluateVenera(plugin, inspection, denials);
        break;
    }
    return ExternalPluginGateDecision(
      denials: denials,
      quarantineReason: quarantineReason,
    );
  }

  void _evaluateMihon(
    ExternalComicPluginCatalogEntry plugin,
    ExternalPluginInspection inspection,
    Set<ExternalPluginDenial> denials,
  ) {
    final expectedPackage = plugin.pluginId.startsWith('mihon:')
        ? plugin.pluginId.substring('mihon:'.length)
        : plugin.pluginId;
    if (inspection.packageName != expectedPackage) {
      denials.add(ExternalPluginDenial.packageMismatch);
    }
    final signer = inspection.signerSha256;
    if (signer == null ||
        trustedMihonSignerSha256.isEmpty ||
        !trustedMihonSignerSha256.contains(_normalizeDigest(signer))) {
      denials.add(ExternalPluginDenial.signerNotTrusted);
    }
    final catalogVersion = plugin.versionCode;
    final inspectedVersion = inspection.versionCode;
    if (catalogVersion != null && inspectedVersion != catalogVersion) {
      denials.add(ExternalPluginDenial.versionMismatch);
    }
    final minimumVersion = minimumVersionCodes[plugin.pluginId];
    if (minimumVersion != null &&
        (inspectedVersion == null || inspectedVersion < minimumVersion)) {
      denials.add(ExternalPluginDenial.versionRollback);
    }
    final extensionLib = inspection.extensionLib;
    if (extensionLib == null ||
        allowedMihonExtensionLibs.isEmpty ||
        !allowedMihonExtensionLibs.contains(extensionLib)) {
      denials.add(ExternalPluginDenial.unsupportedAbi);
    }
    final unexpectedCapabilities =
        inspection.requestedCapabilities.difference(allowedMihonCapabilities);
    if (unexpectedCapabilities.isNotEmpty) {
      denials.add(ExternalPluginDenial.capabilityDenied);
    }
  }

  void _evaluateVenera(
    ExternalComicPluginCatalogEntry plugin,
    ExternalPluginInspection inspection,
    Set<ExternalPluginDenial> denials,
  ) {
    if (!allowedVeneraCapabilities
        .containsAll(inspection.requestedCapabilities)) {
      denials.add(ExternalPluginDenial.capabilityDenied);
    }
    final declared = plugin.sources.map((source) => source.externalId).toSet();
    final inspectedKey = inspection.sourceKey;
    if (plugin.requiresRuntimeDiscovery && inspectedKey == null) {
      denials.add(ExternalPluginDenial.sourceIdentityMismatch);
    } else if (declared.isNotEmpty &&
        (inspectedKey == null || !declared.contains(inspectedKey))) {
      denials.add(ExternalPluginDenial.sourceIdentityMismatch);
    }
  }
}

String _origin(Uri uri) {
  final hasNonDefaultPort = uri.hasPort &&
      !((uri.scheme == 'https' && uri.port == 443) ||
          (uri.scheme == 'http' && uri.port == 80));
  return '${uri.scheme}://${uri.host}'
      '${hasNonDefaultPort ? ':${uri.port}' : ''}';
}

String _normalizeOrigin(String value) => _origin(Uri.parse(value));

String _normalizeDigest(String value) =>
    value.replaceAll(':', '').trim().toLowerCase();

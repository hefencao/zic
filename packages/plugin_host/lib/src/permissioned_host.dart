import 'package:catalog/catalog.dart';

import 'plugin_contract.dart';
import 'plugin_policy.dart';

/// Enforces trust and capability policy before an ecosystem-specific executor
/// receives APK or JavaScript code.
///
/// Inspectors may parse package metadata or script declarations, but must not
/// execute plugin code. Executors remain separate for Mihon-compatible APKs and
/// Venera-compatible JavaScript runtimes.
final class PermissionedExternalComicPluginHost
    implements ExternalComicPluginHost {
  PermissionedExternalComicPluginHost({
    required this.inspector,
    required this.executor,
    required this.policy,
    ExternalPluginQuarantine? quarantine,
    this.quarantineActivationFailures = true,
  }) : quarantine = quarantine ?? MemoryExternalPluginQuarantine() {
    if (inspector.format != executor.format) {
      throw ArgumentError('inspector and executor formats must match');
    }
  }

  final ExternalPluginInspector inspector;
  final ExternalPluginExecutor executor;
  final ExternalPluginTrustPolicy policy;
  final ExternalPluginQuarantine quarantine;
  final bool quarantineActivationFailures;

  @override
  ExternalComicPluginFormat get format => inspector.format;

  @override
  Future<ExternalComicPluginSession> activate(
    ExternalComicPluginCatalogEntry plugin,
  ) async {
    if (plugin.format != format) {
      throw ExternalPluginActivationException(
        pluginId: plugin.pluginId,
        denials: const <ExternalPluginDenial>{
          ExternalPluginDenial.formatMismatch,
        },
      );
    }
    final quarantineReason = quarantine.reasonFor(plugin.pluginId);
    if (quarantineReason != null) {
      throw ExternalPluginActivationException(
        pluginId: plugin.pluginId,
        denials: const <ExternalPluginDenial>{
          ExternalPluginDenial.quarantined,
        },
        cause: StateError(quarantineReason),
      );
    }

    late final ExternalPluginInspection inspection;
    try {
      inspection = await inspector.inspect(plugin);
    } on Object catch (error) {
      if (quarantineActivationFailures) {
        quarantine.quarantine(plugin.pluginId, '$error');
      }
      throw ExternalPluginActivationException(
        pluginId: plugin.pluginId,
        denials: const <ExternalPluginDenial>{
          ExternalPluginDenial.inspectionFailed,
        },
        cause: error,
      );
    }
    final decision = policy.evaluate(
      plugin: plugin,
      inspection: inspection,
    );
    if (!decision.allowed) {
      throw ExternalPluginActivationException(
        pluginId: plugin.pluginId,
        denials: decision.denials,
      );
    }

    try {
      final session = await executor.activate(plugin, inspection);
      final identityDenial = _validateSession(plugin, inspection, session);
      if (identityDenial != null) {
        await session.close();
        quarantine.quarantine(plugin.pluginId, identityDenial.name);
        throw ExternalPluginActivationException(
          pluginId: plugin.pluginId,
          denials: <ExternalPluginDenial>{identityDenial},
        );
      }
      return session;
    } on ExternalPluginActivationException {
      rethrow;
    } on Object catch (error) {
      if (quarantineActivationFailures) {
        quarantine.quarantine(plugin.pluginId, '$error');
      }
      throw ExternalPluginActivationException(
        pluginId: plugin.pluginId,
        denials: const <ExternalPluginDenial>{
          ExternalPluginDenial.activationFailed,
        },
        cause: error,
      );
    }
  }
}

ExternalPluginDenial? _validateSession(
  ExternalComicPluginCatalogEntry plugin,
  ExternalPluginInspection inspection,
  ExternalComicPluginSession session,
) {
  if (session.plugin.pluginId != plugin.pluginId ||
      session.plugin.format != plugin.format) {
    return ExternalPluginDenial.sourceIdentityMismatch;
  }
  final prefix = switch (plugin.format) {
    ExternalComicPluginFormat.mihonExtension => 'mihon:',
    ExternalComicPluginFormat.veneraJavaScript => 'venera:',
  };
  final declared = plugin.sources.map((source) => source.sourceId).toSet();
  final inspectedSourceId =
      plugin.format == ExternalComicPluginFormat.veneraJavaScript &&
              inspection.sourceKey != null
          ? 'venera:${inspection.sourceKey}'
          : null;
  final actual = <String>{};
  for (final source in session.sources) {
    if (!source.sourceId.startsWith(prefix) || !actual.add(source.sourceId)) {
      return ExternalPluginDenial.sourceIdentityMismatch;
    }
    if (declared.isNotEmpty && !declared.contains(source.sourceId)) {
      return ExternalPluginDenial.sourceIdentityMismatch;
    }
    if (inspectedSourceId != null && source.sourceId != inspectedSourceId) {
      return ExternalPluginDenial.sourceIdentityMismatch;
    }
  }
  if (inspectedSourceId != null && actual.length != 1) {
    return ExternalPluginDenial.sourceIdentityMismatch;
  }
  if (declared.isNotEmpty && !actual.containsAll(declared)) {
    return ExternalPluginDenial.sourceIdentityMismatch;
  }
  return null;
}

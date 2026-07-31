import 'package:catalog/catalog.dart';

/// One visible Mihon source plus language variants hidden by default in the
/// source-management projection. Installation records remain independent.
final class MihonSourceLanguageGroup {
  const MihonSourceLanguageGroup({
    required this.groupKey,
    required this.defaultSource,
    required this.otherLanguages,
  });

  final String groupKey;
  final BrowsableComicSource defaultSource;
  final List<BrowsableComicSource> otherLanguages;
}

List<MihonSourceLanguageGroup> groupMihonSourcesByLanguage(
  List<BrowsableComicSource> sources, {
  required String preferredLanguage,
  required String? Function(String sourceId) pluginOwner,
}) {
  final grouped = <String, List<BrowsableComicSource>>{};
  for (final source in sources) {
    grouped.putIfAbsent(
      _mihonSourceFamilyKey(source, pluginOwner(source.sourceId)),
      () => <BrowsableComicSource>[],
    )..add(source);
  }
  final result = <MihonSourceLanguageGroup>[];
  for (final group in grouped.entries) {
    final values = group.value
      ..sort((left, right) {
        final rank = _languageRank(
          left.descriptor.language,
          preferredLanguage,
        ).compareTo(
          _languageRank(right.descriptor.language, preferredLanguage),
        );
        if (rank != 0) return rank;
        return left.descriptor.name.compareTo(right.descriptor.name);
      });
    result.add(
      MihonSourceLanguageGroup(
        groupKey: group.key,
        defaultSource: values.first,
        otherLanguages: List<BrowsableComicSource>.unmodifiable(
          values.skip(1),
        ),
      ),
    );
  }
  return List<MihonSourceLanguageGroup>.unmodifiable(result);
}

String _mihonSourceFamilyKey(
  BrowsableComicSource source,
  String? pluginId,
) {
  final pluginFamily = _mihonPluginFamilyKey(pluginId);
  final host = source.descriptor.website.host.trim().toLowerCase();
  final site = host.isNotEmpty
      ? host
      : source.descriptor.name.trim().toLowerCase();
  return '$pluginFamily|$site';
}

String _mihonPluginFamilyKey(String? pluginId) {
  if (pluginId == null || pluginId.isEmpty) return 'unowned';
  final packageName = pluginId.replaceFirst('mihon:', '');
  final parts = packageName.split('.');
  final extensionIndex = parts.indexOf('extension');
  if (extensionIndex >= 0 && parts.length > extensionIndex + 2) {
    return parts.skip(extensionIndex + 2).join('.').toLowerCase();
  }
  return packageName.toLowerCase();
}

int _languageRank(String language, String preferredLanguage) {
  final normalized = language.trim().toLowerCase();
  final preferred = preferredLanguage.trim().toLowerCase();
  if (normalized == preferred || normalized.startsWith('$preferred-')) {
    return 0;
  }
  if (normalized == 'all' || normalized == 'multi' || normalized == 'mul') {
    return 1;
  }
  if (normalized == 'en') return 2;
  if (normalized == 'und' || normalized.isEmpty) return 4;
  return 3;
}

String externalPluginEntryLanguage(ExternalComicPluginCatalogEntry entry) {
  final explicit = entry.language?.trim();
  if (explicit != null && explicit.isNotEmpty) return explicit;
  final languages = entry.sources
      .map((source) => source.language.trim())
      .where((language) => language.isNotEmpty)
      .toSet();
  if (languages.length == 1) return languages.single;
  if (languages.isNotEmpty) return languages.join('/');
  return 'und';
}

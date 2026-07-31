import 'package:catalog/catalog.dart';

final class MihonLanguageGroup {
  const MihonLanguageGroup({
    required this.groupKey,
    required this.defaultEntry,
    required this.otherLanguages,
  });

  final String groupKey;
  final ExternalComicPluginCatalogEntry defaultEntry;
  final List<ExternalComicPluginCatalogEntry> otherLanguages;
}

List<MihonLanguageGroup> groupMihonEntriesByLanguage(
  List<ExternalComicPluginCatalogEntry> entries, {
  required String preferredLanguage,
}) {
  final grouped = <String, List<ExternalComicPluginCatalogEntry>>{};
  for (final entry in entries) {
    grouped.putIfAbsent(
      mihonPluginFamilyKey(entry),
      () => <ExternalComicPluginCatalogEntry>[],
    )..add(entry);
  }
  final result = <MihonLanguageGroup>[];
  for (final group in grouped.entries) {
    final values = group.value
      ..sort(
        (left, right) => mihonLanguageRank(
          left,
          preferredLanguage,
        ).compareTo(mihonLanguageRank(right, preferredLanguage)),
      );
    result.add(
      MihonLanguageGroup(
        groupKey: group.key,
        defaultEntry: values.first,
        otherLanguages: List<ExternalComicPluginCatalogEntry>.unmodifiable(
          values.skip(1),
        ),
      ),
    );
  }
  result.sort(
    (left, right) => left.defaultEntry.name.compareTo(
      right.defaultEntry.name,
    ),
  );
  return List<MihonLanguageGroup>.unmodifiable(result);
}

String mihonPluginFamilyKey(ExternalComicPluginCatalogEntry entry) {
  final packageName = entry.pluginId.replaceFirst('mihon:', '');
  final parts = packageName.split('.');
  final extensionIndex = parts.indexOf('extension');
  if (extensionIndex >= 0 && parts.length > extensionIndex + 2) {
    return parts.skip(extensionIndex + 2).join('.').toLowerCase();
  }
  return entry.name.trim().toLowerCase();
}

int mihonLanguageRank(
  ExternalComicPluginCatalogEntry entry,
  String preferredLanguage,
) {
  final language = externalPluginEntryLanguage(entry).toLowerCase();
  final preferred = preferredLanguage.toLowerCase();
  if (language == preferred || language.startsWith('$preferred-')) return 0;
  if (language == 'all' || language == 'multi' || language == 'mul') return 1;
  if (language == 'en') return 2;
  if (language == 'und') return 4;
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

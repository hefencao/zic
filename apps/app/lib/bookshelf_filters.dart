import 'package:catalog/catalog.dart';
import 'package:plugin_host_bridge/plugin_host_bridge.dart';

/// Read-only grouping of saved source identities; never activates a plugin.
final class BookshelfPluginGroup {
  BookshelfPluginGroup({required this.id, required this.label, required this.sourceIds, this.format});

  final String id;
  final String label;
  final Set<String> sourceIds;
  final ExternalComicPluginFormat? format;
}

List<BookshelfPluginGroup> groupBookshelfPlugins({
  required Iterable<String> sourceIds,
  required Set<String> localSourceIds,
  required Iterable<BrowsableComicSource> sources,
  required Iterable<InstalledExternalPlugin> installed,
  required String? Function(String) activeOwnerOfSource,
}) {
  final sourceById = {for (final source in sources) source.sourceId: source};
  final pluginById = {for (final record in installed) record.plugin.pluginId: record};
  final declaredOwners = <String, Set<String>>{};
  for (final record in pluginById.values) {
    for (final id in {...record.sourceIds, ...record.plugin.sources.map((source) => source.sourceId)}) {
      declaredOwners.putIfAbsent(id, () => <String>{}).add(record.plugin.pluginId);
    }
  }
  final groups = <String, BookshelfPluginGroup>{};
  for (final sourceId in sourceIds.toSet()) {
    final local = localSourceIds.contains(sourceId);
    final candidates = declaredOwners[sourceId];
    final owner = activeOwnerOfSource(sourceId) ??
        (candidates?.length == 1 ? candidates!.single : null);
    final record = pluginById[owner];
    final id = local ? 'local' : record == null ? 'source:$sourceId' : 'plugin:$owner';
    final source = sourceById[sourceId];
    final names = [
      if (local) '本地',
      if (source != null) source.descriptor.name,
      if (record != null) ...[
        ...record.plugin.sources.map((source) => source.name),
        record.plugin.name,
      ],
      sourceId,
    ];
    final label = names.firstWhere((name) => name.trim().isNotEmpty).trim();
    final format = local ? null : record?.plugin.format ??
        (sourceId.startsWith('mihon:') ? ExternalComicPluginFormat.mihonExtension
          : sourceId.startsWith('venera:') ? ExternalComicPluginFormat.veneraJavaScript : null);
    groups.putIfAbsent(id, () => BookshelfPluginGroup(
      id: id, label: label, sourceIds: <String>{}, format: format,
    )).sourceIds.add(sourceId);
  }
  return groups.values.toList(growable: false);
}

import 'package:catalog/catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_host_bridge/plugin_host_bridge.dart';
import 'package:zic/bookshelf_filters.dart';

InstalledExternalPlugin _plugin(String id, List<String> sourceIds) => InstalledExternalPlugin(
  plugin: ExternalComicPluginCatalogEntry(
    pluginId: id, name: id, format: ExternalComicPluginFormat.mihonExtension,
    version: '1', entrypoint: Uri.https('example.invalid', '/extension.apk'),
    sources: const [], requiresRuntimeDiscovery: true,
  ),
  sourceIds: sourceIds, payloadPath: '/unused/$id.apk', payloadSha256: 'unused',
  repositoryOrigin: 'https://example.invalid',
);

void main() {
  test('saved source identities group without active runtimes or enabled sources', () {
    final groups = groupBookshelfPlugins(
      sourceIds: ['mihon:en', 'mihon:ja', 'folder-a', 'folder-b', 'retired-source'],
      localSourceIds: {'folder-a', 'folder-b'}, sources: const [],
      installed: [_plugin('shared-plugin', ['mihon:en', 'mihon:ja']),
        _plugin('unrepresented-plugin', ['mihon:other'])],
      activeOwnerOfSource: (_) => null,
    );
    expect(groups.map((group) => group.id),
      ['local', 'plugin:shared-plugin', 'source:retired-source']);
    expect(groups.first.sourceIds, {'folder-a', 'folder-b'});
    expect(groups[1].sourceIds, {'mihon:en', 'mihon:ja'});
    expect(groups[1].label, 'shared-plugin');
    expect(groups.last.label, 'retired-source');
  });

  test('ambiguous saved ownership stays source-specific until an active owner proves it', () {
    final records = [_plugin('a', ['mihon:shared']), _plugin('b', ['mihon:shared'])];
    final unresolved = groupBookshelfPlugins(sourceIds: ['mihon:shared'],
      localSourceIds: {}, sources: const [], installed: records, activeOwnerOfSource: (_) => null);
    expect(unresolved.single.id, 'source:mihon:shared');
    final resolved = groupBookshelfPlugins(sourceIds: ['mihon:shared'],
      localSourceIds: {}, sources: const [], installed: records, activeOwnerOfSource: (_) => 'b');
    expect(resolved.single.id, 'plugin:b');
    expect(resolved.single.sourceIds, {'mihon:shared'});
  });
}

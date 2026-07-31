import 'package:catalog/catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/external_plugin_repository_model.dart';

ExternalComicPluginCatalogEntry _mihon({
  required String language,
  required String slug,
}) {
  return ExternalComicPluginCatalogEntry(
    format: ExternalComicPluginFormat.mihonExtension,
    pluginId: 'mihon:eu.kanade.tachiyomi.extension.$language.$slug',
    name: 'Example $slug',
    version: '1.0',
    entrypoint: Uri.parse('https://example.invalid/$language-$slug.apk'),
    sources: <ExternalComicPluginSource>[
      ExternalComicPluginSource(
        sourceId: 'mihon:$language:$slug',
        externalId: '$language:$slug',
        name: slug,
        language: language,
      ),
    ],
    language: language,
  );
}

void main() {
  test('preferred Mihon language stays visible and alternatives are grouped', () {
    final groups = groupMihonEntriesByLanguage(
      <ExternalComicPluginCatalogEntry>[
        _mihon(language: 'en', slug: 'sample'),
        _mihon(language: 'all', slug: 'sample'),
        _mihon(language: 'zh', slug: 'sample'),
        _mihon(language: 'en', slug: 'other'),
      ],
      preferredLanguage: 'zh',
    );

    expect(groups, hasLength(2));
    final sample = groups.singleWhere((group) => group.groupKey == 'sample');
    expect(sample.defaultEntry.language, 'zh');
    expect(
      sample.otherLanguages.map((entry) => entry.language),
      <String?>['all', 'en'],
    );
  });

  test('all-language variant is default when locale variant is absent', () {
    final group = groupMihonEntriesByLanguage(
      <ExternalComicPluginCatalogEntry>[
        _mihon(language: 'en', slug: 'sample'),
        _mihon(language: 'all', slug: 'sample'),
        _mihon(language: 'ja', slug: 'sample'),
      ],
      preferredLanguage: 'zh',
    ).single;

    expect(group.defaultEntry.language, 'all');
  });
}

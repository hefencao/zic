import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/external_plugin_repository_model.dart';

final class _Source implements BrowsableComicSource {
  _Source({
    required this.sourceId,
    required String name,
    required String language,
    required String host,
  }) : descriptor = ComicSourceDescriptor(
          sourceId: sourceId,
          name: name,
          language: language,
          website: Uri.https(host, '/'),
          supportsSearch: true,
          contentRatings: const <SourceContentRating>{SourceContentRating.safe},
        );

  @override
  final String sourceId;

  @override
  final ComicSourceDescriptor descriptor;

  @override
  Future<SourceBrowsePage> browse({
    String query = '',
    int offset = 0,
    int limit = 24,
  }) =>
      throw UnimplementedError();

  @override
  Future<ComicManifest> loadComic(String comicId) => throw UnimplementedError();

  @override
  Future<ChapterManifest> loadChapter(String chapterId) =>
      throw UnimplementedError();

  @override
  Future<Uint8List> loadResource(Uri uri) => throw UnimplementedError();
}

void main() {
  test('preferred Mihon source language stays visible in source management', () {
    final owners = <String, String>{
      'mihon:zh': 'mihon:eu.kanade.tachiyomi.extension.zh.ehentai',
      'mihon:all': 'mihon:eu.kanade.tachiyomi.extension.all.ehentai',
      'mihon:en': 'mihon:eu.kanade.tachiyomi.extension.en.ehentai',
      'mihon:other': 'mihon:eu.kanade.tachiyomi.extension.en.other',
    };
    final groups = groupMihonSourcesByLanguage(
      <BrowsableComicSource>[
        _Source(
          sourceId: 'mihon:en',
          name: 'E-Hentai',
          language: 'en',
          host: 'e-hentai.org',
        ),
        _Source(
          sourceId: 'mihon:all',
          name: 'E-Hentai',
          language: 'all',
          host: 'e-hentai.org',
        ),
        _Source(
          sourceId: 'mihon:zh',
          name: 'E-Hentai',
          language: 'zh',
          host: 'e-hentai.org',
        ),
        _Source(
          sourceId: 'mihon:other',
          name: 'Other',
          language: 'en',
          host: 'other.invalid',
        ),
      ],
      preferredLanguage: 'zh',
      pluginOwner: owners.operator [],
    );

    expect(groups, hasLength(2));
    final ehentai = groups.singleWhere(
      (group) => group.defaultSource.descriptor.website.host == 'e-hentai.org',
    );
    expect(ehentai.defaultSource.descriptor.language, 'zh');
    expect(
      ehentai.otherLanguages.map((source) => source.descriptor.language),
      <String>['all', 'en'],
    );
  });

  test('all-language source is default when locale variant is absent', () {
    final groups = groupMihonSourcesByLanguage(
      <BrowsableComicSource>[
        _Source(
          sourceId: 'mihon:en',
          name: 'Sample',
          language: 'en',
          host: 'sample.invalid',
        ),
        _Source(
          sourceId: 'mihon:all',
          name: 'Sample',
          language: 'all',
          host: 'sample.invalid',
        ),
        _Source(
          sourceId: 'mihon:ja',
          name: 'Sample',
          language: 'ja',
          host: 'sample.invalid',
        ),
      ],
      preferredLanguage: 'zh',
      pluginOwner: (sourceId) => switch (sourceId) {
        'mihon:en' => 'mihon:eu.kanade.tachiyomi.extension.en.sample',
        'mihon:all' => 'mihon:eu.kanade.tachiyomi.extension.all.sample',
        _ => 'mihon:eu.kanade.tachiyomi.extension.ja.sample',
      },
    );

    expect(groups.single.defaultSource.descriptor.language, 'all');
  });
  test('Mihon family order follows persisted source order', () {
    final groups = groupMihonSourcesByLanguage(
      <BrowsableComicSource>[
        _Source(
          sourceId: 'mihon:z',
          name: 'Zed',
          language: 'zh',
          host: 'z.invalid',
        ),
        _Source(
          sourceId: 'mihon:a',
          name: 'Alpha',
          language: 'zh',
          host: 'a.invalid',
        ),
      ],
      preferredLanguage: 'zh',
      pluginOwner: (sourceId) => sourceId == 'mihon:z'
          ? 'mihon:eu.kanade.tachiyomi.extension.zh.zed'
          : 'mihon:eu.kanade.tachiyomi.extension.zh.alpha',
    );

    expect(
      groups.map((group) => group.defaultSource.descriptor.name),
      <String>['Zed', 'Alpha'],
    );
  });

}

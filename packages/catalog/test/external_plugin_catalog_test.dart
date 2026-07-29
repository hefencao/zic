import 'package:catalog/catalog.dart';
import 'package:test/test.dart';

void main() {
  test('parses Mihon repository identities without numeric precision loss', () {
    final entries = parseMihonExtensionIndex(
      '''
      [
        {
          "name": "Tachiyomi: Example",
          "pkg": "eu.kanade.tachiyomi.extension.en.example",
          "apk": "tachiyomi-en.example-v1.2.3.apk",
          "lang": "en",
          "version": "1.2.3",
          "code": 1,
          "nsfw": 1,
          "sources": [
            {
              "name": "Example",
              "lang": "en",
              "id": "9223372036854775808",
              "baseUrl": "https://example.invalid"
            }
          ]
        }
      ]
      ''',
      repositoryBase: Uri.parse('https://repo.invalid/apk/'),
    );

    final plugin = entries.single;
    expect(plugin.pluginId, startsWith('mihon:'));
    expect(
      plugin.entrypoint,
      Uri.parse(
        'https://repo.invalid/apk/tachiyomi-en.example-v1.2.3.apk',
      ),
    );
    expect(plugin.adult, isTrue);
    expect(plugin.versionCode, 1);
    expect(plugin.sources.single.externalId, '9223372036854775808');
    expect(plugin.sources.single.sourceId, 'mihon:9223372036854775808');
  });

  test('parses Venera repository entry and defers script key discovery', () {
    final entries = parseVeneraSourceIndex(
      '''
      [
        {
          "name": "Example JS",
          "filename": "sources/example.js",
          "version": "1.0.0",
          "description": "fixture"
        }
      ]
      ''',
      repositoryBase: Uri.parse('https://repo.invalid/index.json'),
    );

    final plugin = entries.single;
    expect(plugin.format, ExternalComicPluginFormat.veneraJavaScript);
    expect(
      plugin.entrypoint,
      Uri.parse('https://repo.invalid/sources/example.js'),
    );
    expect(plugin.requiresRuntimeDiscovery, isTrue);
    expect(plugin.sources, isEmpty);
  });

  test('parses current Venera fileName and declared key identity', () {
    final entries = parseVeneraSourceIndex(
      '''
      [
        {
          "name": "Copy Manga",
          "fileName": "copy_manga.js",
          "key": "copy_manga",
          "version": "1.4.1"
        }
      ]
      ''',
      repositoryBase: Uri.parse('https://repo.invalid/index.json'),
    );

    final plugin = entries.single;
    expect(plugin.pluginId, 'venera:copy_manga');
    expect(plugin.entrypoint, Uri.parse('https://repo.invalid/copy_manga.js'));
    expect(plugin.requiresRuntimeDiscovery, isFalse);
    expect(plugin.sources.single.externalId, 'copy_manga');
    expect(plugin.sources.single.sourceId, 'venera:copy_manga');
  });

  test('rejects repository entrypoints outside web transport', () {
    expect(
      () => parseVeneraSourceIndex(
        '[{"name":"x","version":"1","url":"file:///tmp/x.js"}]',
      ),
      throwsFormatException,
    );
  });

  test('rejects ambiguous Venera entrypoints', () {
    expect(
      () => parseVeneraSourceIndex(
        '[{"name":"x","version":"1","url":"https://x.invalid/a.js",'
        '"filename":"a.js"}]',
      ),
      throwsFormatException,
    );
  });
}

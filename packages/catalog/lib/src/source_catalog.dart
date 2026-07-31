import 'dart:typed_data';

import 'comic_source.dart';

enum SourceContentRating { safe, suggestive, erotica, pornographic }

enum ComicSourceSettingKind { toggle, text, select, multiSelect, action }

final class ComicSourceSettingChoice {
  const ComicSourceSettingChoice({
    required this.value,
    required this.label,
  });

  final String value;
  final String label;
}

final class ComicSourceSetting {
  ComicSourceSetting({
    required this.key,
    required this.title,
    required this.kind,
    required this.value,
    this.summary,
    this.sensitive = false,
    Iterable<ComicSourceSettingChoice> choices =
        const <ComicSourceSettingChoice>[],
  }) : choices = List<ComicSourceSettingChoice>.unmodifiable(choices) {
    if (key.trim().isEmpty || title.trim().isEmpty) {
      throw ArgumentError('comic source setting identity must not be empty');
    }
  }

  final String key;
  final String title;
  final String? summary;
  final ComicSourceSettingKind kind;
  final Object value;
  final bool sensitive;
  final List<ComicSourceSettingChoice> choices;
}

abstract interface class ConfigurableComicSource {
  Future<List<ComicSourceSetting>> loadSettings();

  Future<void> updateSetting(String key, Object value);
}

final class ComicSourceDescriptor {
  const ComicSourceDescriptor({
    required this.sourceId,
    required this.name,
    required this.language,
    required this.website,
    this.supportsSearch = true,
    this.contentRatings = const <SourceContentRating>{
      SourceContentRating.safe,
      SourceContentRating.suggestive,
    },
  })  : assert(sourceId != ''),
        assert(name != ''),
        assert(language != ''),
        assert(contentRatings.length > 0);

  final String sourceId;
  final String name;
  final String language;
  final Uri website;
  final bool supportsSearch;
  final Set<SourceContentRating> contentRatings;
}

final class SourceComicSummary {
  const SourceComicSummary({
    required this.sourceId,
    required this.comicId,
    required this.title,
    required this.authors,
    this.coverUri,
    this.description,
    this.contentRating = SourceContentRating.safe,
  });

  final String sourceId;
  final String comicId;
  final String title;
  final List<String> authors;
  final Uri? coverUri;
  final String? description;
  final SourceContentRating contentRating;
}

final class SourceBrowsePage {
  SourceBrowsePage({
    required Iterable<SourceComicSummary> items,
    required this.offset,
    required this.hasMore,
  })  : assert(offset >= 0),
        items = List<SourceComicSummary>.unmodifiable(items);

  final List<SourceComicSummary> items;
  final int offset;
  final bool hasMore;
}

abstract interface class BrowsableComicSource implements ComicSource {
  ComicSourceDescriptor get descriptor;

  Future<SourceBrowsePage> browse({
    String query = '',
    int offset = 0,
    int limit = 24,
  });

  Future<Uint8List> loadResource(Uri uri);
}

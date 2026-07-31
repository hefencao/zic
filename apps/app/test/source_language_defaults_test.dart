import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/home_library_session.dart';

void main() {
  test('Mihon source defaults follow Mihon language selection', () {
    const defaults = <String>{'all', 'en', 'zh', 'zh-hans'};

    expect(
      defaultComicSourceEnabled(
        _Source('mihon:all', 'all'),
        defaultLanguages: defaults,
      ),
      isTrue,
    );
    expect(
      defaultComicSourceEnabled(
        _Source('mihon:zh', 'zh-Hans'),
        defaultLanguages: defaults,
      ),
      isTrue,
    );
    expect(
      defaultComicSourceEnabled(
        _Source('mihon:ja', 'ja'),
        defaultLanguages: defaults,
      ),
      isFalse,
    );
    expect(
      defaultComicSourceEnabled(
        _Source('venera:ja', 'ja'),
        defaultLanguages: defaults,
      ),
      isTrue,
    );
  });
}

final class _Source implements BrowsableComicSource {
  _Source(this.sourceId, String language)
      : descriptor = ComicSourceDescriptor(
          sourceId: sourceId,
          name: sourceId,
          language: language,
          website: Uri.parse('https://example.invalid'),
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
  Future<ComicManifest> loadComic(String comicId) =>
      throw UnimplementedError();

  @override
  Future<ChapterManifest> loadChapter(String chapterId) =>
      throw UnimplementedError();

  @override
  Future<Uint8List> loadResource(Uri uri) => throw UnimplementedError();
}

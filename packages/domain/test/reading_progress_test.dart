import 'package:domain/domain.dart';
import 'package:test/test.dart';

void main() {
  test('reading progress round-trips', () {
    final value = ReadingProgress(
      sourceId: 'source',
      comicId: 'comic',
      chapterId: 'chapter',
      pageIndex: 42,
      subPageOffset: 0.25,
      readerMode: ReaderMode.paged,
      updatedAt: DateTime.utc(2026, 7, 26),
    );

    expect(ReadingProgress.fromJson(value.toJson()).toJson(), value.toJson());
  });

  test('legacy reading progress accepts an owning source fallback', () {
    final legacy = <String, Object?>{
      'comicId': 'comic',
      'chapterId': 'chapter',
      'pageIndex': 3,
      'subPageOffset': 0.5,
      'readerMode': ReaderMode.continuous.name,
      'updatedAt': DateTime.utc(2026, 7, 26).toIso8601String(),
    };

    final value = ReadingProgress.fromJson(
      legacy,
      fallbackSourceId: 'legacy-source',
    );

    expect(value.sourceId, 'legacy-source');
    expect(value.identity, 'legacy-source\u0000chapter');
  });

}

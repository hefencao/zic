import 'package:domain/domain.dart';
import 'package:test/test.dart';

void main() {
  test('reading progress round-trips', () {
    final value = ReadingProgress(
      comicId: 'comic',
      chapterId: 'chapter',
      pageIndex: 42,
      subPageOffset: 0.25,
      readerMode: ReaderMode.paged,
      updatedAt: DateTime.utc(2026, 7, 26),
    );

    expect(ReadingProgress.fromJson(value.toJson()).toJson(), value.toJson());
  });
}

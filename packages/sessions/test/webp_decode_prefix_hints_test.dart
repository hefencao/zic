import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';
import 'package:test/test.dart';

void main() {
  test('local partial prefixes advance in one MiB steps per frame key', () {
    final hints = WebpDecodePrefixHints();
    final id = _id(Uri.parse('content://reader/page.webp'));

    expect(hints.minimumBytes(id, 0), 0);
    expect(
      hints.recordNeedMoreData(id: id, frameIndex: 0, sourceLength: 1048576),
      2097152,
    );
    expect(hints.minimumBytes(id, 0), 2097152);
    hints.recordSuccess(id: id, frameIndex: 0, sourceLength: 1572864);
    expect(hints.minimumBytes(id, 0), 1572864);
    expect(hints.minimumBytes(id, 1), 0);
  });

  test('remote partial prefixes advance in 256 KiB steps', () {
    final hints = WebpDecodePrefixHints();
    final id = _id(Uri.parse('https://example.invalid/page.webp'));

    expect(
      hints.recordNeedMoreData(id: id, frameIndex: 2, sourceLength: 300000),
      524288,
    );
    expect(hints.minimumBytes(id, 2), 524288);
  });
}

DownloadId _id(Uri uri) => DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: uri,
    );

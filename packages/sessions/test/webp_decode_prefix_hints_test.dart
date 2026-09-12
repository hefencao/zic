import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';
import 'package:test/test.dart';

void main() {
  test('local partial prefixes retain only the failure-derived retry floor', () {
    final hints = WebpDecodePrefixHints();
    final id = _id(Uri.parse('content://reader/page.webp'));

    expect(hints.minimumBytes(id, 0), 0);
    expect(
      hints.recordNeedMoreData(id: id, frameIndex: 0, sourceLength: 1048576),
      2097152,
    );
    expect(hints.minimumBytes(id, 0), 2097152);
    hints.recordSuccess(id: id, frameIndex: 0, sourceLength: 8 * 1024 * 1024);
    expect(
      hints.minimumBytes(id, 0),
      2097152,
      reason: 'concurrent source growth must not strengthen the retry floor',
    );
    expect(hints.minimumBytes(id, 1), 0);
  });

  test('opportunistic first success does not create a future wait floor', () {
    final hints = WebpDecodePrefixHints();
    final id = _id(Uri.parse('https://example.invalid/page.webp'));

    hints.recordSuccess(
      id: id,
      frameIndex: 0,
      sourceLength: 8216280,
    );

    expect(
      hints.minimumBytes(id, 0),
      0,
      reason: 'success proves sufficiency, not that smaller prefixes failed',
    );
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

  test('physical local replay overrides a remote logical URI quantum', () {
    final hints = WebpDecodePrefixHints();
    final id = _id(Uri.parse('https://example.invalid/page.webp'));

    expect(
      hints.recordNeedMoreData(
        id: id,
        frameIndex: 0,
        sourceLength: 262144,
        quantumBytes: localWebpDecodePrefixQuantumBytes,
      ),
      1048576,
    );
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

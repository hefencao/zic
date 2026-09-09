import 'package:domain/domain.dart';
import 'package:test/test.dart';

void main() {
  test('download identity reuses encoded bytes only for exact revision and URI', () {
    const content = ContentId(
      sourceId: 'local',
      comicId: 'comic',
      chapterId: 'chapter',
      pageId: 'p1',
    );
    final first = DownloadId(
      content: content,
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('assets/p1.png'),
    );
    final same = DownloadId(
      content: content,
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('assets/p1.png'),
    );
    final changed = DownloadId(
      content: content,
      sourceRevision: 'r2',
      canonicalUri: Uri.parse('assets/p1.png'),
    );

    expect(first, same);
    expect(first.hashCode, same.hashCode);
    expect(first, isNot(changed));
  });


  test('delimiters in identity fields cannot collide', () {
    final first = DownloadId(
      content: const ContentId(
        sourceId: 'source/a',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'revision',
      canonicalUri: Uri.parse('https://example.test/page'),
    );
    final second = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'a/comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'revision',
      canonicalUri: Uri.parse('https://example.test/page'),
    );

    expect(first, isNot(second));
    expect(first.key, isNot(second.key));
    expect(first.content.key, isNot(second.content.key));
    expect(first.legacyKey, second.legacyKey);
  });

  test('download identity has a stable JSON round trip', () {
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'local',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'p1',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/p1.webp'),
    );

    expect(DownloadId.fromJson(id.toJson()), id);
  });


  test('page index hint is execution metadata, never download identity', () {
    const content = ContentId(
      sourceId: 'source',
      comicId: 'comic',
      chapterId: 'chapter',
      pageId: 'page',
    );
    final withoutHint = DownloadId(
      content: content,
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/page.webp'),
    );
    final withHint = DownloadId(
      content: content,
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/page.webp'),
      pageIndexHint: 12345,
    );

    expect(withHint, withoutHint);
    expect(withHint.key, withoutHint.key);
    expect(withHint.hashCode, withoutHint.hashCode);
    expect(withHint.toJson(), withoutHint.toJson());
    expect(DownloadId.fromJson(withHint.toJson()).pageIndexHint, isNull);
  });

  test('decode identity includes physical target and renderer', () {
    const content = ContentId(
      sourceId: 'local',
      comicId: 'comic',
      chapterId: 'chapter',
      pageId: 'p1',
    );
    final download = DownloadId(
      content: content,
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('assets/p1.png'),
    );
    final flutter = DecodeId(
      download: download,
      physicalWidth: 1080,
      physicalHeight: 1920,
      pixelFormat: PixelFormat.rgba8888,
      renderer: RendererKind.flutterImage,
    );
    final texture = DecodeId(
      download: download,
      physicalWidth: 1080,
      physicalHeight: 1920,
      pixelFormat: PixelFormat.rgba8888,
      renderer: RendererKind.androidTexture,
    );

    expect(flutter, isNot(texture));
  });

  test('physical target alignment is stable', () {
    expect(alignPhysicalDimension(1081), 1088);
    expect(alignPhysicalDimension(1088), 1088);
  });
}

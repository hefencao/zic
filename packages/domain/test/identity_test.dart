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

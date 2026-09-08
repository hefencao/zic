import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_media_ui/local_media_ui.dart';

void main() {
  test('local WebP stays an animation candidate until runtime classification', () {
    final record = imageFolderChapterRecord(
      PickedImageFolder(
        directoryPath: 'content://provider/tree/chapter',
        displayName: 'chapter',
        files: <PickedImage>[
          PickedImage(
            file: XFile('content://provider/document/001'),
            sourceId: 'content://provider/document/001',
            displayName: '001.webp',
            format: LocalImageFormat.webp,
          ),
          PickedImage(
            file: XFile('content://provider/document/002'),
            sourceId: 'content://provider/document/002',
            displayName: '002.png',
            format: LocalImageFormat.png,
          ),
        ],
      ),
    );

    expect(record.pages.first.animatedHint, isTrue);
    expect(record.pages.last.animatedHint, isFalse);
    expect(record.coverMediaFormat, LocalImageFormat.webp.name);
    expect(record.coverAnimatedHint, isTrue);
  });

  test('root cover image is owned as cover and excluded from Reader pages', () {
    final record = imageFolderChapterRecord(
      PickedImageFolder(
        directoryPath: 'content://provider/tree/chapter',
        displayName: 'chapter',
        files: <PickedImage>[
          PickedImage(
            file: XFile('content://provider/document/001'),
            sourceId: 'content://provider/document/001',
            displayName: '001.webp',
            format: LocalImageFormat.webp,
          ),
          PickedImage(
            file: XFile('content://provider/document/cover'),
            sourceId: 'content://provider/document/cover',
            displayName: 'cover.png',
            format: LocalImageFormat.png,
          ),
          PickedImage(
            file: XFile('content://provider/document/002'),
            sourceId: 'content://provider/document/002',
            displayName: '002.png',
            format: LocalImageFormat.png,
          ),
        ],
      ),
    );

    expect(record.coverSourceId, 'content://provider/document/cover');
    expect(record.coverMediaFormat, LocalImageFormat.png.name);
    expect(record.coverAnimatedHint, isFalse);
    expect(
      record.pages.map((page) => page.sourceId),
      <String>[
        'content://provider/document/001',
        'content://provider/document/002',
      ],
    );
  });

  test('nested cover name remains a Reader page and first page stays cover', () {
    final record = imageFolderChapterRecord(
      PickedImageFolder(
        directoryPath: 'content://provider/tree/chapter',
        displayName: 'chapter',
        files: <PickedImage>[
          PickedImage(
            file: XFile('content://provider/document/001'),
            sourceId: 'content://provider/document/001',
            displayName: '001.webp',
            format: LocalImageFormat.webp,
          ),
          PickedImage(
            file: XFile('content://provider/document/nested-cover'),
            sourceId: 'content://provider/document/nested-cover',
            displayName: 'sub/cover.png',
            format: LocalImageFormat.png,
          ),
        ],
      ),
    );

    expect(record.coverSourceId, 'content://provider/document/001');
    expect(record.pages, hasLength(2));
  });

  test('single explicit cover remains a valid one-page local comic', () {
    final record = imageFolderChapterRecord(
      PickedImageFolder(
        directoryPath: 'content://provider/tree/cover-only',
        displayName: 'cover-only',
        files: <PickedImage>[
          PickedImage(
            file: XFile('content://provider/document/cover'),
            sourceId: 'content://provider/document/cover',
            displayName: 'COVER.WEBP',
            format: LocalImageFormat.webp,
          ),
        ],
      ),
    );

    expect(record.coverSourceId, 'content://provider/document/cover');
    expect(record.coverMediaFormat, LocalImageFormat.webp.name);
    expect(record.coverAnimatedHint, isTrue);
    expect(record.pages.single.sourceId, 'content://provider/document/cover');
  });

}

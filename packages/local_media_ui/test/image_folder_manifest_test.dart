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
  });
}

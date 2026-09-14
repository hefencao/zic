import 'package:flutter_test/flutter_test.dart';
import 'package:zic/chapter_download_directory.dart';

void main() {
  test('SAF chapter directory unwraps to the exact content tree URI', () {
    const tree =
        'content://com.android.externalstorage.documents/tree/primary%3Aunkloser%2Fzic';
    expect(chapterDownloadSafTreeUri('saf://$tree'), tree);
  });

  test('direct chapter directory is not treated as SAF', () {
    expect(chapterDownloadSafTreeUri('/data/user/0/dev.zic.zic/files/zic'), isNull);
  });
}

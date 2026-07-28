import 'package:file_selector/file_selector.dart';

import 'local_image_folder.dart';

@Deprecated('Use LocalImageDirectorySelector')
typedef LocalWebpDirectorySelector = LocalImageDirectorySelector;

@Deprecated('Use LocalImageDirectoryLoader')
typedef LocalWebpDirectoryLoader = Future<List<XFile>> Function(String path);

@Deprecated('Use selectLocalImageDirectory')
Future<String?> selectLocalWebpDirectory() => selectLocalImageDirectory();

@Deprecated('Use listLocalImageDirectory')
Future<List<XFile>> listLocalWebpDirectory(String path) async {
  final scan = await listLocalImageDirectory(path);
  return List<XFile>.unmodifiable(
    scan.images
        .where((image) => image.format == LocalImageFormat.webp)
        .map((image) => image.file),
  );
}

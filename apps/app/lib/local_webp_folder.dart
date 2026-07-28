import 'package:file_selector/file_selector.dart';

import 'local_webp_folder_stub.dart'
    if (dart.library.io) 'local_webp_folder_io.dart' as platform;

typedef LocalWebpDirectorySelector = Future<String?> Function();
typedef LocalWebpDirectoryLoader = Future<List<XFile>> Function(String path);

Future<String?> selectLocalWebpDirectory() => getDirectoryPath();

Future<List<XFile>> listLocalWebpDirectory(String path) =>
    platform.listLocalWebpDirectory(path);

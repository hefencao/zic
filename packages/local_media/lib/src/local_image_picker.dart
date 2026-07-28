import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import 'local_image_model.dart';
import 'local_image_platform_stub.dart'
    if (dart.library.io) 'local_image_platform_io.dart' as platform;

typedef LocalImageDirectorySelector = Future<String?> Function();
typedef LocalImageDirectoryLoader = Future<LocalImageDirectoryScan> Function(
  String path,
);
typedef LocalImageDirectoryContentsPicker =
    Future<LocalImageDirectorySelection?> Function();
typedef LocalImageDirectoryRefresher =
    Future<LocalImageDirectorySelection> Function(String directoryId);

Future<String?> selectLocalImageDirectory() => getDirectoryPath();

bool get prefersScopedLocalImageDirectoryPicker =>
    platform.prefersScopedLocalImageDirectoryPicker;

Future<LocalImageDirectorySelection?> pickScopedLocalImageDirectory() =>
    platform.pickScopedLocalImageDirectory();

Future<LocalImageDirectorySelection> refreshLocalImageDirectory(
  String directoryId,
) =>
    platform.refreshLocalImageDirectory(directoryId);

Future<LocalImageDirectoryScan> listLocalImageDirectory(String path) =>
    platform.listLocalImageDirectory(path);

Future<Uint8List> readLocalImageSource(String sourceId) =>
    platform.readLocalImageSource(sourceId);

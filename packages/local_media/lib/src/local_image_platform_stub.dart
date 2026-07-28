import 'dart:typed_data';

import 'local_image_model.dart';

bool get prefersScopedLocalImageDirectoryPicker => false;

Future<LocalImageDirectorySelection?> pickScopedLocalImageDirectory() {
  throw UnsupportedError('当前平台不支持 scoped-storage 图片文件夹导入');
}

Future<LocalImageDirectorySelection> refreshLocalImageDirectory(
  String directoryId,
) {
  throw UnsupportedError('当前平台不支持刷新本地图片文件夹：$directoryId');
}

Future<LocalImageDirectoryScan> listLocalImageDirectory(String path) {
  throw UnsupportedError('当前平台不支持本地图片文件夹枚举：$path');
}

Future<Uint8List> readLocalImageSource(String sourceId) {
  throw UnsupportedError('当前平台不支持读取本地图片来源：$sourceId');
}

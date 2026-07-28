import 'local_image_model.dart';

bool get prefersScopedLocalImageDirectoryPicker => false;

Future<LocalImageDirectorySelection?> pickScopedLocalImageDirectory() {
  throw UnsupportedError('当前平台不支持 scoped-storage 图片文件夹导入');
}

Future<LocalImageDirectoryScan> listLocalImageDirectory(String path) {
  throw UnsupportedError('当前平台不支持本地图片文件夹枚举：$path');
}

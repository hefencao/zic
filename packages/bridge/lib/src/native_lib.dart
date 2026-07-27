import 'dart:ffi';
import 'dart:io';

DynamicLibrary openNativeLib(String? path) {
  if (path != null) {
    return DynamicLibrary.open(path);
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('libmedia_core.so');
  }
  if (Platform.isMacOS || Platform.isIOS) {
    return DynamicLibrary.open('libmedia_core.dylib');
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('media_core.dll');
  }
  throw UnsupportedError('unsupported platform: ${Platform.operatingSystem}');
}

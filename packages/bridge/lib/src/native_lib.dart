import 'dart:ffi';
import 'dart:io';

final Map<String, DynamicLibrary> _nativeLibraries = <String, DynamicLibrary>{};

String nativeLibraryCacheKey(String? path) {
  if (path != null) return path;
  if (Platform.isAndroid || Platform.isLinux) return 'libmedia_core.so';
  if (Platform.isMacOS || Platform.isIOS) return 'libmedia_core.dylib';
  if (Platform.isWindows) return 'media_core.dll';
  throw UnsupportedError('unsupported platform: ${Platform.operatingSystem}');
}

DynamicLibrary openNativeLib(String? path) {
  final key = nativeLibraryCacheKey(path);
  return _nativeLibraries.putIfAbsent(key, () => DynamicLibrary.open(key));
}

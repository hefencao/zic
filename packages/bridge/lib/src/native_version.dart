import 'dart:ffi';
import 'dart:io';

typedef _VersionNative = Uint32 Function();
typedef _VersionDart = int Function();

final class NativeVersion {
  const NativeVersion({required this.abiVersion, required this.libVersion});

  final int abiVersion;
  final int libVersion;

  static NativeVersion load({String? libPath}) {
    final lib = libPath == null
        ? DynamicLibrary.open(_defaultLibraryName())
        : DynamicLibrary.open(libPath);
    final abi = lib.lookupFunction<_VersionNative, _VersionDart>(
      'zic_abi_version',
    );
    final version = lib.lookupFunction<_VersionNative, _VersionDart>(
      'zic_version',
    );
    return NativeVersion(
      abiVersion: abi(),
      libVersion: version(),
    );
  }

  static String _defaultLibraryName() {
    if (Platform.isAndroid || Platform.isLinux) {
      return 'libmedia_core.so';
    }
    if (Platform.isMacOS || Platform.isIOS) {
      return 'libmedia_core.dylib';
    }
    if (Platform.isWindows) {
      return 'media_core.dll';
    }
    throw UnsupportedError('unsupported platform: ${Platform.operatingSystem}');
  }
}

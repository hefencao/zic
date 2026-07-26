import 'dart:ffi';
import 'dart:io';

typedef _VersionNative = Uint32 Function();
typedef _VersionDart = int Function();

final class NativeVersion {
  const NativeVersion({required this.abiVersion, required this.libraryVersion});

  final int abiVersion;
  final int libraryVersion;

  static NativeVersion load({String? libraryPath}) {
    final library = libraryPath == null
        ? DynamicLibrary.open(_defaultLibraryName())
        : DynamicLibrary.open(libraryPath);
    final abi = library.lookupFunction<_VersionNative, _VersionDart>(
      'zic_abi_version',
    );
    final version = library.lookupFunction<_VersionNative, _VersionDart>(
      'zic_version',
    );
    return NativeVersion(
      abiVersion: abi(),
      libraryVersion: version(),
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

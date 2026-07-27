import 'dart:ffi';

import 'native_lib.dart';

typedef _VersionNative = Uint32 Function();
typedef _VersionDart = int Function();

final class NativeVersion {
  const NativeVersion({required this.abiVersion, required this.libVersion});

  final int abiVersion;
  final int libVersion;

  static NativeVersion load({String? libPath}) {
    final lib = openNativeLib(libPath);
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
}

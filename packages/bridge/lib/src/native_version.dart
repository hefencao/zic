import 'dart:ffi';

import 'native_lib.dart';

typedef _VersionNative = Uint32 Function();
typedef _VersionDart = int Function();

final class NativeVersion {
  const NativeVersion({
    required this.abiVersion,
    required this.libVersion,
    required this.webpDecoderVersion,
    required this.webpDemuxVersion,
  });

  final int abiVersion;
  final int libVersion;
  final int webpDecoderVersion;
  final int webpDemuxVersion;

  bool get usesPinnedWebp =>
      webpDecoderVersion == 0x00010600 && webpDemuxVersion == 0x00010600;

  static NativeVersion load({String? libPath}) {
    final lib = openNativeLib(libPath);
    final abi = lib.lookupFunction<_VersionNative, _VersionDart>(
      'zic_abi_version',
    );
    final version = lib.lookupFunction<_VersionNative, _VersionDart>(
      'zic_version',
    );
    final decoder = lib.lookupFunction<_VersionNative, _VersionDart>(
      'zic_webp_decoder_version',
    );
    final demux = lib.lookupFunction<_VersionNative, _VersionDart>(
      'zic_webp_demux_version',
    );
    return NativeVersion(
      abiVersion: abi(),
      libVersion: version(),
      webpDecoderVersion: decoder(),
      webpDemuxVersion: demux(),
    );
  }
}

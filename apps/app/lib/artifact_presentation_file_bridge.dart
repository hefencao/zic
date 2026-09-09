import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const String artifactPresentationFileChannelName = 'dev.zic.zic/saf_store';

@immutable
final class AndroidArtifactPresentationFileHandle {
  const AndroidArtifactPresentationFileHandle({
    required this.handle,
    required this.path,
    required this.length,
  });

  final int handle;
  final String path;
  final int length;
}

/// Android descriptor bridge used only to pin an immutable encoded body while
/// Flutter's engine codec may open/reopen it. Body bytes never cross the
/// MethodChannel.
final class AndroidArtifactPresentationFileBridge {
  const AndroidArtifactPresentationFileBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(artifactPresentationFileChannelName);

  final MethodChannel _channel;

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<AndroidArtifactPresentationFileHandle?> openDirect(String path) =>
      _open('presentationOpenDirect', <String, Object?>{'path': path});

  Future<AndroidArtifactPresentationFileHandle?> openSaf({
    required String treeUri,
    required String relativePath,
  }) =>
      _open('presentationOpenSaf', <String, Object?>{
        'treeUri': treeUri,
        'relativePath': relativePath,
      });

  Future<AndroidArtifactPresentationFileHandle?> _open(
    String method,
    Map<String, Object?> arguments,
  ) async {
    if (!isSupported) return null;
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        method,
        arguments,
      );
      if (raw == null) return null;
      final handle = raw['handle'];
      final path = raw['path'];
      final length = raw['length'];
      if (handle is! int ||
          path is! String ||
          path.isEmpty ||
          length is! int ||
          length < 0) {
        throw const FormatException('artifact presentation descriptor is invalid');
      }
      return AndroidArtifactPresentationFileHandle(
        handle: handle,
        path: path,
        length: length,
      );
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> close(int handle) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>(
        'presentationClose',
        <String, Object?>{'handle': handle},
      );
    } on MissingPluginException {
      // The process/plugin is already gone; the OS owns descriptor cleanup.
    } on PlatformException catch (error) {
      if (error.code != 'saf-io-failure') rethrow;
    }
  }
}

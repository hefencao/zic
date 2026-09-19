import 'dart:async';

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
  AndroidArtifactPresentationFileBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(artifactPresentationFileChannelName);

  final MethodChannel _channel;
  final Set<int> _pendingCloseHandles = <int>{};
  final Map<int, List<Completer<void>>> _pendingCloseWaiters =
      <int, List<Completer<void>>>{};
  bool _closeFlushScheduled = false;

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

  Future<void> close(int handle) {
    if (!isSupported) return Future<void>.value();
    final waiter = Completer<void>();
    _pendingCloseHandles.add(handle);
    (_pendingCloseWaiters[handle] ??= <Completer<void>>[]).add(waiter);
    if (!_closeFlushScheduled) {
      _closeFlushScheduled = true;
      scheduleMicrotask(() => _flushCloses(_channel));
    }
    return waiter.future;
  }

  Future<void> _flushCloses(MethodChannel channel) async {
    _closeFlushScheduled = false;
    if (_pendingCloseHandles.isEmpty) return;
    final handles = _pendingCloseHandles.toList(growable: false);
    _pendingCloseHandles.removeAll(handles);
    Object? failure;
    try {
      await channel.invokeMethod<void>(
        'presentationCloseMany',
        <String, Object?>{'handles': handles},
      );
    } on MissingPluginException {
      // The process/plugin is already gone; the OS owns descriptor cleanup.
    } on PlatformException catch (error) {
      if (error.code != 'saf-io-failure') failure = error;
    } on Object catch (error) {
      failure = error;
    } finally {
      for (final handle in handles) {
        final waiters = _pendingCloseWaiters.remove(handle);
        if (waiters == null) continue;
        for (final waiter in waiters) {
          if (failure == null) {
            waiter.complete();
          } else {
            waiter.completeError(failure);
          }
        }
      }
      if (_pendingCloseHandles.isNotEmpty && !_closeFlushScheduled) {
        _closeFlushScheduled = true;
        scheduleMicrotask(() => _flushCloses(channel));
      }
    }
  }
}

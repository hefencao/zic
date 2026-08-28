import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart client for the SAF byte bridge (`dev.zic.zic/saf_store`).
///
/// The bridge owns a native descriptor table of
/// `ParcelFileDescriptor`-backed handles, giving random-access reads and
/// writes inside a persisted SAF tree without any storage permission.
///
/// Ownership contract: the tree URI comes from `pickDirectory` (persistable
/// grant taken at pick time); the SQLite index never lives in the tree — it
/// stays app-private and binds to the tree URI by preference.
class SafStore {
  SafStore({required this.treeUri})
    : _channel = const MethodChannel('dev.zic.zic/saf_store');

  final String treeUri;
  final MethodChannel _channel;

  bool _available = true;

  Future<T> _invoke<T>(
    Future<Object?> Function(MethodChannel channel) action,
    T Function() fallback,
    T Function(Object? raw) parse,
  ) async {
    if (!_available) return fallback();
    try {
      final raw = await action(_channel);
      if (raw == null) return fallback();
      return parse(raw);
    } on MissingPluginException catch (_) {
      _available = false;
      return fallback();
    }
  }

  /// Opens (creating intermediate files when [mode] allows) and returns a
  /// handle; null when the store bridge is unavailable on this platform.
  Future<int?> open(
    String relativePath, {
    SafMode mode = SafMode.read,
  }) {
    return _invoke<int?>(
      (channel) => channel.invokeMethod('safOpen', <String, Object?>{
        'treeUri': treeUri,
        'relativePath': relativePath,
        'mode': mode.name,
      }),
      () => null,
      (raw) => raw as int,
    );
  }

  Future<Uint8List> read(int handle, int length) {
    return _invoke<Uint8List>(
      (channel) => channel.invokeMethod('safRead', <String, Object?>{
        'handle': handle,
        'length': length,
      }),
      () => Uint8List(0),
      (raw) => raw! as Uint8List,
    );
  }

  Future<void> write(int handle, Uint8List bytes) async {
    await _invoke<Object?>(
      (channel) => channel.invokeMethod('safWrite', <String, Object?>{
        'handle': handle,
        'bytes': bytes,
      }),
      () => null,
      (raw) => raw,
    );
  }

  Future<void> seek(int handle, int position) async {
    await _invoke<Object?>(
      (channel) => channel.invokeMethod('safSeek', <String, Object?>{
        'handle': handle,
        'position': position,
      }),
      () => null,
      (raw) => raw,
    );
  }

  Future<int?> length(int handle) {
    return _invoke<int?>(
      (channel) => channel.invokeMethod('safLength', <String, Object?>{
        'handle': handle,
      }),
      () => null,
      (raw) => raw as int,
    );
  }

  Future<void> close(int handle) async {
    await _invoke<Object?>(
      (channel) => channel.invokeMethod('safClose', <String, Object?>{
        'handle': handle,
      }),
      () => null,
      (raw) => raw,
    );
  }

  Future<bool> delete(String relativePath) {
    return _invoke<bool>(
      (channel) => channel.invokeMethod('safDelete', <String, Object?>{
        'treeUri': treeUri,
        'relativePath': relativePath,
      }),
      () => false,
      (raw) => raw == true,
    );
  }

  Future<bool> exists(String relativePath) {
    return _invoke<bool>(
      (channel) => channel.invokeMethod('safExists', <String, Object?>{
        'treeUri': treeUri,
        'relativePath': relativePath,
      }),
      () => false,
      (raw) => raw == true,
    );
  }

  Future<List<SafEntry>> list(String relativePath) {
    return _invoke<List<SafEntry>>(
      (channel) => channel.invokeMethod('safList', <String, Object?>{
        'treeUri': treeUri,
        'relativePath': relativePath,
      }),
      () => const <SafEntry>[],
      (raw) {
        if (raw is! List) return const <SafEntry>[];
        return raw.map((item) {
          final map = Map<String, Object?>.from(item as Map);
          return SafEntry(
            name: map['name'] as String? ?? '',
            isDirectory: map['isDirectory'] == true,
            length: (map['length'] as num?)?.toInt() ?? 0,
          );
        }).toList();
      },
    );
  }
}

final class SafEntry {
  const SafEntry({
    required this.name,
    required this.isDirectory,
    required this.length,
  });

  final String name;
  final bool isDirectory;
  final int length;
}

enum SafMode { read, writeAppend, writeTruncate }

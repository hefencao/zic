import 'package:downloads/downloads.dart';
import 'package:flutter/services.dart';

import 'saf_store.dart';

/// Binds the app-side SAF channel client to the downloads package's
/// transport interface. Lives here because platform channels are an app
/// concern; the package stays testable with fakes.
class SafTreeIoAdapter
    implements
        SafTreeIo,
        SafTreeRandomRead,
        SafTreeReadPrewarmer {
  SafTreeIoAdapter(this._store);

  final SafStore _store;

  @override
  Future<bool> prewarmReadProvider() =>
      _readOperation<bool>('prewarm-read-provider', _store.prewarmRecentRead);

  Future<T> _readOperation<T>(
    String operation,
    Future<T> Function() action,
  ) async {
    try {
      return await action();
    } on PlatformException catch (error) {
      throw SafTreeAccessFailure(
        kind: switch (error.code) {
          'saf-access-denied' => ArtifactReadFailureKind.accessDenied,
          'saf-missing' => ArtifactReadFailureKind.missing,
          'saf-stale-locator' => ArtifactReadFailureKind.staleLocator,
          _ => ArtifactReadFailureKind.ioFailure,
        },
        operation: operation,
        cause: error,
      );
    }
  }

  @override
  Future<int?> open(
    String relativePath, {
    SafWriteMode mode = SafWriteMode.read,
  }) {
    Future<int?> operation() => _store.open(
          relativePath,
          mode: switch (mode) {
            SafWriteMode.read => SafMode.read,
            SafWriteMode.writeAppend => SafMode.writeAppend,
            SafWriteMode.writeTruncate => SafMode.writeTruncate,
          },
        );
    return mode == SafWriteMode.read
        ? _readOperation<int?>('open', operation)
        : operation();
  }

  @override
  Future<Uint8List> read(int handle, int length) =>
      _readOperation<Uint8List>('read', () => _store.read(handle, length));

  @override
  Future<Uint8List> readAt(int handle, int position, int length) =>
      _readOperation<Uint8List>(
        'readAt',
        () => _store.readAt(handle, position, length),
      );

  @override
  Future<void> write(int handle, Uint8List bytes) =>
      _store.write(handle, bytes);

  @override
  Future<void> seek(int handle, int position) =>
      _readOperation<void>('seek', () => _store.seek(handle, position));

  @override
  Future<void> close(int handle) => _store.close(handle);

  @override
  Future<bool> delete(String relativePath) => _store.delete(relativePath);

  @override
  Future<bool> exists(String relativePath) =>
      _readOperation<bool>('exists', () => _store.exists(relativePath));

  @override
  Future<bool> rename(String relativePath, String newRelativePath) =>
      _store.rename(relativePath, newRelativePath);

  @override
  Future<int?> length(int handle) =>
      _readOperation<int?>('length', () => _store.length(handle));

  @override
  Future<List<SafTreeFile>> list(String relativePath) async {
    final entries = await _store.list(relativePath);
    return entries
        .map(
          (e) => SafTreeFile(
            name: e.name,
            isDirectory: e.isDirectory,
            length: e.length,
          ),
        )
        .toList();
  }
}

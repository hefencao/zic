import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';

import 'runtime_protocol.dart';

/// Consumer of a body claimed and integrity-checked by the platform packet
/// owner. The open handle and all reads retire before that owner releases it.
final class ExternalPluginRuntimeFileBody implements ComicResourceBody {
  ExternalPluginRuntimeFileBody._(this.reference, this._file, this._release);

  static Future<ExternalPluginRuntimeFileBody> openVerified({
    required ExternalPluginRuntimeBodyFile reference,
    required String path,
    required Future<void> Function() release,
    Future<RandomAccessFile> Function(String)? openFile,
  }) async {
    RandomAccessFile? file;
    try {
      file = await (openFile?.call(path) ?? File(path).open());
      if (await file.length() != reference.byteLength) {
        throw const Failure(
          code: ErrorCode.source,
          message: 'claimed runtime body length changed',
        );
      }
      return ExternalPluginRuntimeFileBody._(reference, file, release);
    } on Object {
      try {
        await file?.close();
      } finally {
        await release();
      }
      rethrow;
    }
  }

  final ExternalPluginRuntimeBodyFile reference;
  final RandomAccessFile _file;
  final Future<void> Function() _release;
  Future<void> _physicalRead = Future<void>.value();
  Future<void>? _disposeFuture;
  bool _streamOpened = false;
  bool _retiring = false;

  @override
  int get byteLength => reference.byteLength;

  @override
  Uint8List get metadataPrefix => reference.metadataPrefix;

  @override
  String get validator => reference.validator;

  @override
  Stream<List<int>> open({int start = 0, int? end}) {
    final limit = end ?? byteLength;
    if (start < 0 || limit < start || limit > byteLength) {
      throw RangeError('runtime body range is outside its sealed length');
    }
    _throwIfRetiring();
    if (_streamOpened) {
      throw StateError('runtime body already has a consumer');
    }
    _streamOpened = true;
    return _read(start, limit);
  }

  Stream<List<int>> _read(int start, int end) async* {
    try {
      await _physical(() => _file.setPosition(start));
      var remaining = end - start;
      while (remaining > 0) {
        final chunk = await _physical(
          () => _file.read(math.min(remaining, 64 * 1024)),
        );
        if (chunk.isEmpty) {
          throw const Failure(
            code: ErrorCode.source,
            message: 'claimed runtime body ended before its sealed length',
          );
        }
        remaining -= chunk.length;
        yield chunk;
      }
    } finally {
      await dispose();
    }
  }

  Future<T> _physical<T>(Future<T> Function() operation) async {
    _throwIfRetiring();
    final pending = operation();
    _physicalRead = pending.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    final value = await pending;
    _throwIfRetiring();
    return value;
  }

  void _throwIfRetiring() {
    if (_retiring) {
      throw const Failure(
        code: ErrorCode.cancelled,
        message: 'runtime body consumer was retired',
      );
    }
  }

  @override
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    _retiring = true;
    return _disposeFuture = _dispose();
  }

  Future<void> _dispose() async {
    await _physicalRead;
    try {
      await _file.close();
    } finally {
      await _release();
    }
  }
}

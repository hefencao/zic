import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:media/media.dart';

import 'native_lib.dart';

part 'native_cursor.dart';
part 'native_decode_pool.dart';

final class _Source extends Opaque {}

/// Starts the two native decode worker isolates before first page use.
///
/// Workers are retained across Reader sessions inside one App composition so
/// re-entry does not repay isolate startup. A host that is about to destroy its
/// FlutterEngine while keeping the Android process alive must call
/// [shutdownNativeDecodeWorkers] first; otherwise each replacement engine can
/// leave the previous isolate group's decode arenas mapped in the process.
Future<void> prewarmNativeDecodeWorkers({String? libPath}) =>
    _NativeDecodeWorkerPool.forLibrary(libPath).prewarm();

/// Shuts down the decode workers owned by the current Dart/App composition.
///
/// The pool entry is removed before shutdown, so a later composition in the
/// same Dart isolate can create a fresh pool. Callers must first dispose active
/// decode sessions; shutdown rejects a pool that still has active native work.
Future<void> shutdownNativeDecodeWorkers({String? libPath}) =>
    _NativeDecodeWorkerPool.shutdownForLibrary(libPath);

typedef _CreateNative = Pointer<_Source> Function(Uint64 epoch, UintPtr maxBytes);
typedef _CreateDart = Pointer<_Source> Function(int epoch, int maxBytes);
typedef _FreeNative = Void Function(Pointer<_Source> source);
typedef _FreeDart = void Function(Pointer<_Source> source);
typedef _ReserveCapacityNative = Uint32 Function(
  Pointer<_Source> source,
  Uint64 epoch,
  UintPtr capacity,
);
typedef _ReserveCapacityDart = int Function(
  Pointer<_Source> source,
  int epoch,
  int capacity,
);
typedef _ReserveNative = Uint32 Function(
  Pointer<_Source> source,
  Uint64 epoch,
  UintPtr offset,
  UintPtr length,
  Pointer<Pointer<Uint8>> outData,
);
typedef _ReserveDart = int Function(
  Pointer<_Source> source,
  int epoch,
  int offset,
  int length,
  Pointer<Pointer<Uint8>> outData,
);
typedef _CommitNative = Uint32 Function(
  Pointer<_Source> source,
  Uint64 epoch,
  UintPtr offset,
  UintPtr length,
);
typedef _CommitDart = int Function(
  Pointer<_Source> source,
  int epoch,
  int offset,
  int length,
);
typedef _AppendNative = Uint32 Function(
  Pointer<_Source> source,
  Uint64 epoch,
  UintPtr offset,
  Pointer<Uint8> data,
  UintPtr length,
);
typedef _AppendDart = int Function(
  Pointer<_Source> source,
  int epoch,
  int offset,
  Pointer<Uint8> data,
  int length,
);
typedef _EpochOpNative = Uint32 Function(Pointer<_Source> source, Uint64 epoch);
typedef _EpochOpDart = int Function(Pointer<_Source> source, int epoch);
typedef _LenNative = UintPtr Function(Pointer<_Source> source);
typedef _LenDart = int Function(Pointer<_Source> source);
typedef _EpochNative = Uint64 Function(Pointer<_Source> source);
typedef _EpochDart = int Function(Pointer<_Source> source);
typedef _U32Native = Uint32 Function(Pointer<_Source> source);
typedef _U32Dart = int Function(Pointer<_Source> source);

final class NativeSourceFactory implements SourceFactory {
  const NativeSourceFactory({this.libPath});

  final String? libPath;

  @override
  EncodedSource create({required int epoch, required int maxBytes}) {
    return NativeSource.create(
      epoch: epoch,
      maxBytes: maxBytes,
      libPath: libPath,
    );
  }
}

final class NativeSource implements EncodedSource, ExpectedLengthEncodedSource {
  NativeSource._(this._ptr, this._api);

  factory NativeSource.create({
    required int epoch,
    required int maxBytes,
    String? libPath,
  }) {
    if (epoch < 0 || maxBytes < 0) {
      throw ArgumentError('epoch and maxBytes must be non-negative');
    }
    final api = _SourceApi(openNativeLib(libPath));
    final ptr = api.create(epoch, maxBytes);
    if (ptr == nullptr) {
      throw StateError('native source allocation failed');
    }
    return NativeSource._(ptr, api);
  }

  Pointer<_Source> _ptr;
  final _SourceApi _api;

  bool get disposed => _ptr == nullptr;
  @override
  int get length => _api.length(_requirePtr());
  @override
  int get epoch => _api.epoch(_requirePtr());
  @override
  bool get sealed => _api.isSealed(_requirePtr()) != 0;
  @override
  SourceKind get kind => SourceKind.values[_api.kind(_requirePtr())];

  @override
  SourceStatus reserveExpectedLength({
    required int epoch,
    required int length,
  }) => SourceStatus.values[
        _api.reserveCapacity(_requirePtr(), epoch, length)
      ];

  @override
  SourceStatus append({
    required int epoch,
    required int offset,
    required List<int> bytes,
  }) {
    final ptr = _requirePtr();
    if (bytes.isEmpty) {
      return SourceStatus.values[_api.commit(ptr, epoch, offset, 0)];
    }
    final outData = calloc<Pointer<Uint8>>();
    try {
      final reserve = SourceStatus.values[
        _api.reserve(ptr, epoch, offset, bytes.length, outData)
      ];
      if (reserve != SourceStatus.ok) {
        return reserve;
      }
      final destination = outData.value;
      if (destination == nullptr) {
        return SourceStatus.failed;
      }
      destination.asTypedList(bytes.length).setAll(0, bytes);
      return SourceStatus.values[
        _api.commit(ptr, epoch, offset, bytes.length)
      ];
    } finally {
      calloc.free(outData);
    }
  }

  @override
  SourceStatus seal(int epoch) =>
      SourceStatus.values[_api.seal(_requirePtr(), epoch)];

  @override
  SourceStatus reset(int epoch) =>
      SourceStatus.values[_api.reset(_requirePtr(), epoch)];

  @override
  void dispose() {
    final ptr = _ptr;
    if (ptr == nullptr) {
      return;
    }
    _ptr = nullptr;
    _api.free(ptr);
  }

  Pointer<_Source> _requirePtr() {
    if (_ptr == nullptr) {
      throw StateError('native source is disposed');
    }
    return _ptr;
  }
}

final class _SourceApi {
  _SourceApi(DynamicLibrary lib)
      : create = lib.lookupFunction<_CreateNative, _CreateDart>(
          'zic_source_create',
        ),
        free = lib.lookupFunction<_FreeNative, _FreeDart>('zic_source_free'),
        reserveCapacity = lib.lookupFunction<
            _ReserveCapacityNative,
            _ReserveCapacityDart
          >('zic_source_reserve_capacity'),
        reserve = lib.lookupFunction<_ReserveNative, _ReserveDart>(
          'zic_source_reserve',
        ),
        commit = lib.lookupFunction<_CommitNative, _CommitDart>(
          'zic_source_commit',
        ),
        append = lib.lookupFunction<_AppendNative, _AppendDart>(
          'zic_source_append',
        ),
        seal = lib.lookupFunction<_EpochOpNative, _EpochOpDart>(
          'zic_source_seal',
        ),
        reset = lib.lookupFunction<_EpochOpNative, _EpochOpDart>(
          'zic_source_reset',
        ),
        length = lib.lookupFunction<_LenNative, _LenDart>('zic_source_len'),
        epoch = lib.lookupFunction<_EpochNative, _EpochDart>(
          'zic_source_epoch',
        ),
        isSealed = lib.lookupFunction<_U32Native, _U32Dart>(
          'zic_source_is_sealed',
        ),
        kind = lib.lookupFunction<_U32Native, _U32Dart>('zic_source_kind');

  final _CreateDart create;
  final _FreeDart free;
  final _ReserveCapacityDart reserveCapacity;
  final _ReserveDart reserve;
  final _CommitDart commit;
  final _AppendDart append;
  final _EpochOpDart seal;
  final _EpochOpDart reset;
  final _LenDart length;
  final _EpochDart epoch;
  final _U32Dart isSealed;
  final _U32Dart kind;
}

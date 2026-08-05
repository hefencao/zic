part of 'native_source.dart';

const int _nativeDecodeWorkerCount = 2;

final class _NativeDecodeResult {
  const _NativeDecodeResult({
    required this.status,
    required this.frameAddress,
    required this.frameCount,
    required this.loopCount,
    required this.metadataComplete,
    required this.cycle,
    required this.nativeMicros,
    required this.nativeMetadataMicros,
    required this.workerRoundTripMicros,
    required this.workerReadyMicros,
    required this.workerQueueMicros,
    required this.workerIndex,
    required this.workerPlacementStatus,
  });

  final int status;
  final int frameAddress;
  final int frameCount;
  final int loopCount;
  final bool metadataComplete;
  final int cycle;
  final int nativeMicros;
  final int nativeMetadataMicros;
  final int workerRoundTripMicros;
  final int workerReadyMicros;
  final int workerQueueMicros;
  final int workerIndex;
  final int workerPlacementStatus;
}

/// Process-lifetime pool: page/cursor disposal never owns worker shutdown.
///
/// With two workers, at most one non-current decode may run concurrently. The
/// other slot remains available to current work, matching the playback path's
/// single high-priority reservation without adding native nested thread pools.
final class _NativeDecodeWorkerPool {
  _NativeDecodeWorkerPool._(this.libPath);

  static final Map<String, _NativeDecodeWorkerPool> _instances =
      <String, _NativeDecodeWorkerPool>{};

  static _NativeDecodeWorkerPool forLibrary(String? libPath) {
    final key = libPath ?? '<default>';
    return _instances.putIfAbsent(
      key,
      () => _NativeDecodeWorkerPool._(libPath),
    );
  }

  final String? libPath;
  final Queue<_PendingNativeDecode> _currentPending =
      Queue<_PendingNativeDecode>();
  final Queue<_PendingNativeDecode> _nonCurrentPending =
      Queue<_PendingNativeDecode>();
  final List<_NativeDecodeWorker> _workers = <_NativeDecodeWorker>[];
  Future<void>? _starting;

  Future<void> prewarm() => _ensureStarted();

  Future<List<_NativeDecodeResult>> decodeBatch({
    required int cursorAddress,
    required int epoch,
    required DecodeExecutionClass executionClass,
    required int maxFrames,
  }) {
    if (maxFrames <= 0 || maxFrames > 2) {
      throw ArgumentError.value(maxFrames, 'maxFrames', 'must be 1 or 2');
    }
    final completer = Completer<List<_NativeDecodeResult>>();
    final pending = _PendingNativeDecode(
      cursorAddress: cursorAddress,
      epoch: epoch,
      executionClass: executionClass,
      maxFrames: maxFrames,
      completer: completer,
      workerReady: Stopwatch()..start(),
    );
    _enqueue(pending);
    if (_workers.length == _nativeDecodeWorkerCount) {
      pending.markWorkersReady();
      _pump();
    } else {
      unawaited(
        _ensureStarted().catchError((Object error, StackTrace stack) {
          _removePending(pending);
          if (!pending.completer.isCompleted) {
            pending.completer.completeError(error, stack);
          }
        }),
      );
    }
    return completer.future;
  }

  DecodePriorityPromotion promotePendingDecodeToCurrent({
    required int cursorAddress,
    required int epoch,
  }) {
    for (final pending in List<_PendingNativeDecode>.of(_nonCurrentPending)) {
      if (pending.cursorAddress != cursorAddress || pending.epoch != epoch) {
        continue;
      }
      _nonCurrentPending.remove(pending);
      pending.executionClass = DecodeExecutionClass.current;
      _currentPending.addFirst(pending);
      _pump();
      return DecodePriorityPromotion.queued;
    }
    for (final worker in _workers) {
      if (!worker.busy ||
          worker.cursorAddress != cursorAddress ||
          worker.epoch != epoch) {
        continue;
      }
      if (worker.executionClass == DecodeExecutionClass.current) {
        return DecodePriorityPromotion.none;
      }
      worker.executionClass = DecodeExecutionClass.current;
      return DecodePriorityPromotion.active;
    }
    return DecodePriorityPromotion.none;
  }

  void _enqueue(_PendingNativeDecode pending) {
    if (pending.executionClass == DecodeExecutionClass.current) {
      _currentPending.addLast(pending);
    } else {
      _nonCurrentPending.addLast(pending);
    }
  }

  void _removePending(_PendingNativeDecode pending) {
    _currentPending.remove(pending);
    _nonCurrentPending.remove(pending);
  }

  Future<void> _ensureStarted() {
    final existing = _starting;
    if (existing != null) {
      return existing;
    }
    final future = _start();
    _starting = future;
    return future;
  }

  Future<void> _start() async {
    final started = <_NativeDecodeWorker>[];
    try {
      for (var index = 0; index < _nativeDecodeWorkerCount; index++) {
        started.add(await _spawnWorker(index));
      }
      _workers.addAll(started);
      _markQueuedWorkersReady();
      _pump();
    } on Object {
      for (final worker in started) {
        worker.close();
      }
      _starting = null;
      rethrow;
    }
  }

  Future<_NativeDecodeWorker> _spawnWorker(int index) async {
    final ready = ReceivePort();
    try {
      await Isolate.spawn<List<Object?>>(
        _nativeDecodeWorkerEntry,
        <Object?>[ready.sendPort, libPath, index],
        debugName: 'zic-webp-decode-$index',
      );
      final value = await ready.first;
      if (value is! List<Object?> ||
          value.length < 2 ||
          value[0] is! SendPort ||
          value[1] is! int) {
        throw StateError('native decode worker failed to start: $value');
      }
      return _NativeDecodeWorker(
        value[0]! as SendPort,
        index,
        value[1]! as int,
      );
    } finally {
      ready.close();
    }
  }

  void _markQueuedWorkersReady() {
    for (final pending in <_PendingNativeDecode>[
      ..._currentPending,
      ..._nonCurrentPending,
    ]) {
      pending.markWorkersReady();
    }
  }

  void _pump() {
    for (final worker in _workers) {
      if (worker.busy) {
        continue;
      }
      final pending = _takePending();
      if (pending == null) {
        return;
      }
      worker.busy = true;
      worker.executionClass = pending.executionClass;
      worker.cursorAddress = pending.cursorAddress;
      worker.epoch = pending.epoch;
      unawaited(_run(worker, pending));
    }
  }

  _PendingNativeDecode? _takePending() {
    if (_currentPending.isNotEmpty && _currentPending.first.workersReady) {
      return _currentPending.removeFirst();
    }
    final nonCurrentBusy = _workers.where(
      (worker) =>
          worker.busy &&
          worker.executionClass == DecodeExecutionClass.nonCurrent,
    ).length;
    if (_nonCurrentPending.isNotEmpty &&
        _nonCurrentPending.first.workersReady &&
        nonCurrentBusy < _nativeDecodeWorkerCount - 1) {
      return _nonCurrentPending.removeFirst();
    }
    return null;
  }

  Future<void> _run(
    _NativeDecodeWorker worker,
    _PendingNativeDecode pending,
  ) async {
    try {
      final workerQueueMicros = pending.queued?.elapsedMicroseconds ?? 0;
      final results = await worker.decodeBatch(
        cursorAddress: pending.cursorAddress,
        epoch: pending.epoch,
        maxFrames: pending.maxFrames,
      );
      final nativeTotal = results.fold<int>(
        0,
        (sum, result) =>
            sum + result.nativeMicros + result.nativeMetadataMicros,
      );
      final batchRoundTrip = results.isEmpty
          ? 0
          : results.first.workerRoundTripMicros;
      final sharedDispatch = results.isEmpty
          ? 0
          : ((batchRoundTrip - nativeTotal).clamp(0, 1 << 62) ~/
              results.length);
      pending.completer.complete(
        <_NativeDecodeResult>[
          for (var index = 0; index < results.length; index++)
            _NativeDecodeResult(
              status: results[index].status,
              frameAddress: results[index].frameAddress,
              frameCount: results[index].frameCount,
              loopCount: results[index].loopCount,
              metadataComplete: results[index].metadataComplete,
              cycle: results[index].cycle,
              nativeMicros: results[index].nativeMicros,
              nativeMetadataMicros: results[index].nativeMetadataMicros,
              workerRoundTripMicros: results[index].nativeMicros +
                  results[index].nativeMetadataMicros +
                  sharedDispatch,
              workerReadyMicros: index == 0 ? pending.workerReadyMicros : 0,
              workerQueueMicros: index == 0 ? workerQueueMicros : 0,
              workerIndex: worker.index,
              workerPlacementStatus: worker.placementStatus,
            ),
        ],
      );
    } on Object catch (error, stack) {
      pending.completer.completeError(error, stack);
    } finally {
      worker.busy = false;
      worker.executionClass = null;
      worker.cursorAddress = null;
      worker.epoch = null;
      _pump();
    }
  }
}

final class _PendingNativeDecode {
  _PendingNativeDecode({
    required this.cursorAddress,
    required this.epoch,
    required this.executionClass,
    required this.maxFrames,
    required this.completer,
    required this.workerReady,
  });

  final int cursorAddress;
  final int epoch;
  DecodeExecutionClass executionClass;
  final int maxFrames;
  final Completer<List<_NativeDecodeResult>> completer;
  final Stopwatch workerReady;
  int workerReadyMicros = 0;
  Stopwatch? queued;
  bool workersReady = false;

  void markWorkersReady() {
    if (workersReady) {
      return;
    }
    workersReady = true;
    workerReadyMicros = workerReady.elapsedMicroseconds;
    queued = Stopwatch()..start();
  }
}

final class _NativeDecodeWorker {
  _NativeDecodeWorker(this.port, this.index, this.placementStatus);

  final SendPort port;
  final int index;
  final int placementStatus;
  bool busy = false;
  DecodeExecutionClass? executionClass;
  int? cursorAddress;
  int? epoch;

  void close() {
    port.send('close');
  }

  Future<List<_NativeDecodeResult>> decodeBatch({
    required int cursorAddress,
    required int epoch,
    required int maxFrames,
  }) async {
    final response = ReceivePort();
    final workerRoundTrip = Stopwatch()..start();
    try {
      port.send(<Object?>[
        response.sendPort,
        cursorAddress,
        epoch,
        maxFrames,
      ]);
      final value = await response.first;
      if (value is! List<Object?> || value.isEmpty) {
        throw StateError('invalid native decode worker response: $value');
      }
      if (value.first == 'error') {
        throw StateError(
          value.length > 1 ? value[1].toString() : 'decode failed',
        );
      }
      final elapsed = workerRoundTrip.elapsedMicroseconds;
      final results = <_NativeDecodeResult>[];
      for (final item in value) {
        if (item is! List<Object?> || item.length < 8) {
          throw StateError('incomplete native decode worker response: $item');
        }
        results.add(
          _NativeDecodeResult(
            status: item[0]! as int,
            frameAddress: item[1]! as int,
            frameCount: item[2]! as int,
            loopCount: item[3]! as int,
            metadataComplete: item[4] == true,
            cycle: item[5]! as int,
            nativeMicros: item[6]! as int,
            nativeMetadataMicros: item[7]! as int,
            workerRoundTripMicros: elapsed,
            workerReadyMicros: 0,
            workerQueueMicros: 0,
            workerIndex: index,
            workerPlacementStatus: placementStatus,
          ),
        );
      }
      return List<_NativeDecodeResult>.unmodifiable(results);
    } finally {
      response.close();
    }
  }

}

@pragma('vm:entry-point')
void _nativeDecodeWorkerEntry(List<Object?> arguments) {
  final ready = arguments[0]! as SendPort;
  final libPath = arguments[1] as String?;
  final receive = ReceivePort();
  late final _CursorApi api;
  try {
    api = _CursorApi(openNativeLib(libPath));
  } on Object catch (error) {
    ready.send('native library load failed: $error');
    receive.close();
    return;
  }
  const placementStatus = 0;
  ready.send(<Object?>[receive.sendPort, placementStatus]);
  receive.listen((Object? message) {
    if (message == 'close') {
      receive.close();
      Isolate.exit();
    }
    if (message is! List<Object?> || message.length < 4) {
      return;
    }
    final reply = message[0]! as SendPort;
    final cursorAddress = message[1]! as int;
    final epoch = message[2]! as int;
    final maxFrames = message[3]! as int;
    final out = calloc<Pointer<_Frame>>();
    final decoded = <List<Object?>>[];
    try {
      final cursor = Pointer<_Cursor>.fromAddress(cursorAddress);
      for (var index = 0; index < maxFrames; index++) {
        out.value = nullptr;
        final stopwatch = Stopwatch()..start();
        final status = api.decode(cursor, epoch, out);
        final nativeMicros = stopwatch.elapsedMicroseconds;
        final metadataStopwatch = Stopwatch()..start();
        final frameAddress = out.value == nullptr ? 0 : out.value.address;
        final frameCount = api.frameCount(cursor);
        final loopCount = api.loopCount(cursor);
        final metadataComplete = api.metadataComplete(cursor) != 0;
        final cycle = api.cycle(cursor);
        final nativeMetadataMicros = metadataStopwatch.elapsedMicroseconds;
        decoded.add(<Object?>[
          status,
          frameAddress,
          frameCount,
          loopCount,
          metadataComplete,
          cycle,
          nativeMicros,
          nativeMetadataMicros,
        ]);
        if (status != _CursorStatus.ok.index) {
          break;
        }
      }
      reply.send(decoded);
    } on Object catch (error) {
      final released = <int>{};
      for (final result in decoded) {
        final address = result[1] as int? ?? 0;
        if (address != 0 && released.add(address)) {
          api.frameRelease(Pointer<_Frame>.fromAddress(address));
        }
      }
      final frame = out.value;
      if (frame != nullptr && released.add(frame.address)) {
        api.frameRelease(frame);
      }
      reply.send(<Object?>['error', error.toString()]);
    } finally {
      calloc.free(out);
    }
  });
}

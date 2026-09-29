part of 'native_source.dart';

const int _nativeDecodeWorkerCount = 2;
final Object _decodeWorkerExitedSignal = Object();

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
    required this.nativePrepareMicros,
    required this.nativeCanvasPrepareMicros,
    required this.nativeFragmentDecodeMicros,
    required this.nativeCompositeMicros,
    required this.nativeFrameCopyMicros,
    required this.nativeThreadId,
    required this.nativeCpuStart,
    required this.nativeCpuEnd,
    required this.nativeCpuAllowedMask,
    required this.nativeKnownFrameCount,
    required this.nativeFullCanvasFrameCount,
    required this.nativeIndependentFrameCount,
    required this.nativeMaxDependentRun,
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
  final int nativePrepareMicros;
  final int nativeCanvasPrepareMicros;
  final int nativeFragmentDecodeMicros;
  final int nativeCompositeMicros;
  final int nativeFrameCopyMicros;
  final int nativeThreadId;
  final int nativeCpuStart;
  final int nativeCpuEnd;
  final int nativeCpuAllowedMask;
  final int nativeKnownFrameCount;
  final int nativeFullCanvasFrameCount;
  final int nativeIndependentFrameCount;
  final int nativeMaxDependentRun;
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

  static Future<void> shutdownForLibrary(String? libPath) async {
    final key = libPath ?? '<default>';
    final pool = _instances[key];
    if (pool == null) return;
    await pool.shutdown();
    if (identical(_instances[key], pool)) {
      _instances.remove(key);
    }
  }

  final String? libPath;
  final Queue<_PendingNativeDecode> _currentPending =
      Queue<_PendingNativeDecode>();
  final Queue<_PendingNativeDecode> _nonCurrentPending =
      Queue<_PendingNativeDecode>();
  final List<_NativeDecodeWorker> _workers = <_NativeDecodeWorker>[];
  Future<void>? _starting;
  Future<void>? _replenishing;
  Future<void>? _shutdown;
  bool _started = false;
  bool _shuttingDown = false;
  int _activeRuns = 0;

  Future<void> prewarm() => _ensureStarted();

  Future<void> shutdown() {
    final existing = _shutdown;
    if (existing != null) return existing;
    late final Future<void> shutdown;
    shutdown = _shutdownWorkers();
    _shutdown = shutdown;
    return shutdown;
  }

  Future<void> _shutdownWorkers() async {
    _shuttingDown = true;
    final starting = _starting;
    if (starting != null) {
      try {
        await starting;
      } on Object {
        // A failed startup already closes any workers it managed to create.
      }
    }
    final replenishing = _replenishing;
    if (replenishing != null) {
      try {
        await replenishing;
      } on Object {
        // Replacement failure is already delivered to queued callers.
      }
    }
    if (_currentPending.isNotEmpty || _nonCurrentPending.isNotEmpty) {
      final failure = StateError('native decode worker pool shut down');
      for (final pending in <_PendingNativeDecode>[
        ..._currentPending,
        ..._nonCurrentPending,
      ]) {
        if (!pending.completer.isCompleted) {
          pending.completer.completeError(failure);
        }
      }
      _currentPending.clear();
      _nonCurrentPending.clear();
    }
    if (_activeRuns > 0) {
      throw StateError(
        'cannot shut down native decode workers while decode work is active',
      );
    }
    final workers = _workers.toList(growable: false);
    _workers.clear();
    await Future.wait<void>(
      workers.map((worker) => worker.close()),
      eagerError: false,
    );
  }

  Future<List<_NativeDecodeResult>> decodeBatch({
    required int cursorAddress,
    required int epoch,
    required DecodeExecutionClass executionClass,
    required int maxFrames,
  }) {
    if (_shuttingDown) {
      return Future<List<_NativeDecodeResult>>.error(
        StateError('native decode worker pool is shutting down'),
      );
    }
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
    if (_started) {
      pending.markWorkersReady();
      _pump();
      _ensureWorkerCapacity();
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
    if (_shuttingDown) {
      return Future<void>.error(
        StateError('native decode worker pool is shutting down'),
      );
    }
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
      _started = true;
      for (final worker in started) {
        worker.attachExitHandler(_handleWorkerExit);
      }
      _markQueuedWorkersReady();
      _pump();
    } on Object {
      await Future.wait<void>(
        started.map((worker) => worker.close()),
        eagerError: false,
      );
      _starting = null;
      rethrow;
    }
  }

  Future<_NativeDecodeWorker> _spawnWorker(int index) async {
    final ready = ReceivePort();
    try {
      final isolate = await Isolate.spawn<List<Object?>>(
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
        isolate,
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
    for (final worker in _workers.toList(growable: false)) {
      if (worker.busy || worker.exited) {
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
      _activeRuns++;
      unawaited(_run(worker, pending));
    }
  }

  _PendingNativeDecode? _takePending() {
    if (_currentPending.isNotEmpty && _currentPending.first.workersReady) {
      return _currentPending.removeFirst();
    }
    final nonCurrentBusy = _workers.where(
      (worker) =>
          !worker.exited &&
          worker.busy &&
          worker.executionClass == DecodeExecutionClass.nonCurrent,
    ).length;
    final liveWorkerCount =
        _workers.where((worker) => !worker.exited).length;
    if (_nonCurrentPending.isNotEmpty &&
        _nonCurrentPending.first.workersReady &&
        nonCurrentBusy < liveWorkerCount - 1) {
      return _nonCurrentPending.removeFirst();
    }
    return null;
  }

  void _handleWorkerExit(_NativeDecodeWorker worker) {
    final removed = _workers.remove(worker);
    if (!removed || _shuttingDown) return;
    _pump();
    _ensureWorkerCapacity();
  }

  void _ensureWorkerCapacity() {
    if (_shuttingDown || !_started ||
        _workers.length >= _nativeDecodeWorkerCount ||
        _replenishing != null) {
      return;
    }
    late final Future<void> replenishing;
    replenishing = _replenishWorkers().whenComplete(() {
      if (identical(_replenishing, replenishing)) {
        _replenishing = null;
      }
    });
    _replenishing = replenishing;
    unawaited(replenishing);
  }

  Future<void> _replenishWorkers() async {
    while (!_shuttingDown && _workers.length < _nativeDecodeWorkerCount) {
      final occupied = _workers.map((worker) => worker.index).toSet();
      var index = 0;
      while (occupied.contains(index)) {
        index++;
      }
      try {
        final worker = await _spawnWorker(index);
        if (_shuttingDown) {
          await worker.close();
          return;
        }
        _workers.add(worker);
        worker.attachExitHandler(_handleWorkerExit);
      } on Object catch (error, stack) {
        final failure = StateError(
          'native decode worker replacement failed: $error',
        );
        for (final pending in <_PendingNativeDecode>[
          ..._currentPending,
          ..._nonCurrentPending,
        ]) {
          if (!pending.completer.isCompleted) {
            pending.completer.completeError(failure, stack);
          }
        }
        _currentPending.clear();
        _nonCurrentPending.clear();
        return;
      }
    }
    _markQueuedWorkersReady();
    _pump();
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
              nativePrepareMicros: results[index].nativePrepareMicros,
              nativeCanvasPrepareMicros:
                  results[index].nativeCanvasPrepareMicros,
              nativeFragmentDecodeMicros:
                  results[index].nativeFragmentDecodeMicros,
              nativeCompositeMicros: results[index].nativeCompositeMicros,
              nativeFrameCopyMicros: results[index].nativeFrameCopyMicros,
              nativeThreadId: results[index].nativeThreadId,
              nativeCpuStart: results[index].nativeCpuStart,
              nativeCpuEnd: results[index].nativeCpuEnd,
              nativeCpuAllowedMask: results[index].nativeCpuAllowedMask,
              nativeKnownFrameCount: results[index].nativeKnownFrameCount,
              nativeFullCanvasFrameCount:
                  results[index].nativeFullCanvasFrameCount,
              nativeIndependentFrameCount:
                  results[index].nativeIndependentFrameCount,
              nativeMaxDependentRun: results[index].nativeMaxDependentRun,
            ),
        ],
      );
    } on Object catch (error, stack) {
      pending.completer.completeError(error, stack);
    } finally {
      _activeRuns--;
      worker.busy = false;
      worker.executionClass = null;
      worker.cursorAddress = null;
      worker.epoch = null;
      if (!_shuttingDown) {
        _pump();
      }
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
  _NativeDecodeWorker(
    this.port,
    this.index,
    this.placementStatus,
    this.isolate,
  ) {
    isolate.addOnExitListener(_exitPort.sendPort);
    _exitPort.listen((_) {
      if (exited) return;
      exited = true;
      final active = _activeResponse;
      if (active != null && !active.isCompleted) {
        active.complete(_decodeWorkerExitedSignal);
      }
      if (!_exitCompleter.isCompleted) {
        _exitCompleter.complete();
      }
      _exitPort.close();
      _onExit?.call(this);
    });
  }

  final SendPort port;
  final int index;
  final int placementStatus;
  final Isolate isolate;
  final ReceivePort _exitPort = ReceivePort();
  final Completer<void> _exitCompleter = Completer<void>();
  Completer<Object?>? _activeResponse;
  void Function(_NativeDecodeWorker worker)? _onExit;
  bool exited = false;
  bool busy = false;
  DecodeExecutionClass? executionClass;
  int? cursorAddress;
  int? epoch;

  void attachExitHandler(void Function(_NativeDecodeWorker worker) onExit) {
    _onExit = onExit;
    if (exited) {
      onExit(this);
    }
  }

  Future<void> close() async {
    if (exited) {
      await _exitCompleter.future;
      return;
    }
    port.send('close');
    try {
      await _exitCompleter.future.timeout(const Duration(milliseconds: 500));
    } on TimeoutException {
      isolate.kill(priority: Isolate.immediate);
      await _exitCompleter.future;
    }
  }

  Future<List<_NativeDecodeResult>> decodeBatch({
    required int cursorAddress,
    required int epoch,
    required int maxFrames,
  }) async {
    if (exited) {
      throw StateError('native decode worker exited before request');
    }
    if (_activeResponse != null) {
      throw StateError('native decode worker received concurrent request');
    }
    final response = ReceivePort();
    final completed = Completer<Object?>();
    _activeResponse = completed;
    final workerRoundTrip = Stopwatch()..start();
    late final StreamSubscription<Object?> responseSubscription;
    responseSubscription = response.listen((value) {
      if (!completed.isCompleted) {
        completed.complete(value);
      }
    });
    try {
      port.send(<Object?>[
        response.sendPort,
        cursorAddress,
        epoch,
        maxFrames,
      ]);
      final value = await completed.future;
      if (identical(value, _decodeWorkerExitedSignal)) {
        throw StateError('native decode worker exited before responding');
      }
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
        if (item is! List<Object?> || item.length < 21) {
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
            nativePrepareMicros: item[8]! as int,
            nativeCanvasPrepareMicros: item[9]! as int,
            nativeFragmentDecodeMicros: item[10]! as int,
            nativeCompositeMicros: item[11]! as int,
            nativeFrameCopyMicros: item[12]! as int,
            nativeThreadId: item[13]! as int,
            nativeCpuStart: item[14]! as int,
            nativeCpuEnd: item[15]! as int,
            nativeCpuAllowedMask: item[16]! as int,
            nativeKnownFrameCount: item[17]! as int,
            nativeFullCanvasFrameCount: item[18]! as int,
            nativeIndependentFrameCount: item[19]! as int,
            nativeMaxDependentRun: item[20]! as int,
          ),
        );
      }
      return List<_NativeDecodeResult>.unmodifiable(results);
    } finally {
      if (identical(_activeResponse, completed)) {
        _activeResponse = null;
      }
      await responseSubscription.cancel();
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

      List<Object?> resultFor({
        required int status,
        required Pointer<_Frame> frame,
        required int nativeMicros,
      }) {
        final metadataStopwatch = Stopwatch()..start();
        final frameAddress = frame == nullptr ? 0 : frame.address;
        final frameCount = api.frameCount(cursor);
        final loopCount = api.loopCount(cursor);
        final metadataComplete = api.metadataComplete(cursor) != 0;
        final cycle = api.cycle(cursor);
        final nativeKnownFrameCount = api.knownFrameCount(cursor);
        final nativeFullCanvasFrameCount = api.fullCanvasFrameCount(cursor);
        final nativeIndependentFrameCount = api.independentFrameCount(cursor);
        final nativeMaxDependentRun = api.maxDependentRun(cursor);
        final nativeMetadataMicros = metadataStopwatch.elapsedMicroseconds;
        return <Object?>[
          status,
          frameAddress,
          frameCount,
          loopCount,
          metadataComplete,
          cycle,
          nativeMicros,
          nativeMetadataMicros,
          frameAddress == 0 ? 0 : api.frameNativePrepareUs(frame),
          frameAddress == 0 ? 0 : api.frameNativeCanvasPrepareUs(frame),
          frameAddress == 0 ? 0 : api.frameNativeFragmentDecodeUs(frame),
          frameAddress == 0 ? 0 : api.frameNativeCompositeUs(frame),
          frameAddress == 0 ? 0 : api.frameNativeFrameCopyUs(frame),
          frameAddress == 0 ? 0 : api.frameNativeThreadId(frame),
          frameAddress == 0 ? -1 : api.frameNativeCpuStart(frame),
          frameAddress == 0 ? -1 : api.frameNativeCpuEnd(frame),
          frameAddress == 0 ? 0 : api.frameNativeCpuAllowedMask(frame),
          nativeKnownFrameCount,
          nativeFullCanvasFrameCount,
          nativeIndependentFrameCount,
          nativeMaxDependentRun,
        ];
      }

      for (var index = 0; index < maxFrames; index++) {
        out.value = nullptr;
        final stopwatch = Stopwatch()..start();
        final status = api.decode(cursor, epoch, out);
        final nativeMicros = stopwatch.elapsedMicroseconds;
        decoded.add(
          resultFor(
            status: status,
            frame: out.value,
            nativeMicros: nativeMicros,
          ),
        );
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

part of 'native_source.dart';

const int _nativeSourceWriteWorkerCount = 2;
final Object _sourceWriteWorkerExitedSignal = Object();

enum _NativeSourceWriteOperation { reserveCapacity, append, appendFileRange }

final class _NativeSourceWriteWorkerPool {
  _NativeSourceWriteWorkerPool._(this.libPath);

  static final Map<String, _NativeSourceWriteWorkerPool> _instances =
      <String, _NativeSourceWriteWorkerPool>{};

  static _NativeSourceWriteWorkerPool forLibrary(String? libPath) {
    final key = libPath ?? '<default>';
    return _instances.putIfAbsent(
      key,
      () => _NativeSourceWriteWorkerPool._(libPath),
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
  final List<_PendingNativeSourceWrite> _pending = <_PendingNativeSourceWrite>[];
  final List<_NativeSourceWriteWorker> _workers = <_NativeSourceWriteWorker>[];
  Future<void>? _starting;
  Future<void>? _shutdown;
  Completer<void>? _idleCompleter;
  bool _shuttingDown = false;
  int _nextSequence = 0;

  Future<void> prewarm() => _ensureStarted();

  Future<int> reserveCapacity({
    required int sourceAddress,
    required int epoch,
    required int length,
    TaskControl? control,
  }) => _submit(
    _PendingNativeSourceWrite(
      operation: _NativeSourceWriteOperation.reserveCapacity,
      sourceAddress: sourceAddress,
      epoch: epoch,
      offset: 0,
      length: length,
      control: control,
      sequence: _nextSequence++,
    ),
  );

  Future<int> append({
    required int sourceAddress,
    required int epoch,
    required int offset,
    required List<int> bytes,
    TaskControl? control,
  }) {
    final typed = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    return _submit(
      _PendingNativeSourceWrite(
        operation: _NativeSourceWriteOperation.append,
        sourceAddress: sourceAddress,
        epoch: epoch,
        offset: offset,
        length: typed.lengthInBytes,
        bytes: TransferableTypedData.fromList(<TypedData>[typed]),
        control: control,
        sequence: _nextSequence++,
      ),
    );
  }

  Future<int> appendFileRange({
    required int sourceAddress,
    required int epoch,
    required int offset,
    required String path,
    required int fileOffset,
    required int length,
    TaskControl? control,
  }) => _submit(
    _PendingNativeSourceWrite(
      operation: _NativeSourceWriteOperation.appendFileRange,
      sourceAddress: sourceAddress,
      epoch: epoch,
      offset: offset,
      length: length,
      path: path,
      fileOffset: fileOffset,
      control: control,
      sequence: _nextSequence++,
    ),
  );

  Future<int> _submit(_PendingNativeSourceWrite pending) {
    if (_shuttingDown) {
      return Future<int>.error(
        StateError('native source write worker pool is shutting down'),
      );
    }
    final submittedControl = pending.control;
    if (submittedControl?.cancelled == true) {
      try {
        submittedControl!.throwIfCancelled();
      } on Object catch (error, stackTrace) {
        return Future<int>.error(error, stackTrace);
      }
    }
    _pending.add(pending);
    final control = pending.control;
    if (control != null) {
      unawaited(control.whenCancelled.then((_) {
        if (_pending.remove(pending) && !pending.completer.isCompleted) {
          try {
            control.throwIfCancelled();
          } on Object catch (error, stackTrace) {
            pending.completer.completeError(error, stackTrace);
          }
          _notifyIdle();
        }
      }));
    }
    if (_workers.length == _nativeSourceWriteWorkerCount) {
      _pump();
    } else {
      unawaited(
        _ensureStarted().catchError((Object error, StackTrace stack) {
          if (_pending.remove(pending) && !pending.completer.isCompleted) {
            pending.completer.completeError(error, stack);
          }
          _notifyIdle();
        }),
      );
    }
    return pending.completer.future;
  }

  Future<void> shutdown() {
    final existing = _shutdown;
    if (existing != null) return existing;
    final future = _shutdownWorkers();
    _shutdown = future;
    return future;
  }

  Future<void> _shutdownWorkers() async {
    _shuttingDown = true;
    final starting = _starting;
    if (starting != null) {
      try {
        await starting;
      } on Object {
        // Startup failure is already delivered to queued callers.
      }
    }
    await _idle();
    final workers = _workers.toList(growable: false);
    _workers.clear();
    await Future.wait<void>(
      workers.map((worker) => worker.close()),
      eagerError: false,
    );
  }

  Future<void> _idle() {
    if (_pending.isEmpty && _workers.every((worker) => !worker.busy)) {
      return Future<void>.value();
    }
    return (_idleCompleter ??= Completer<void>()).future;
  }

  Future<void> _ensureStarted() {
    final existing = _starting;
    if (existing != null) return existing;
    final future = _start();
    _starting = future;
    return future;
  }

  Future<void> _start() async {
    final started = <_NativeSourceWriteWorker>[];
    try {
      for (var index = 0; index < _nativeSourceWriteWorkerCount; index++) {
        started.add(await _spawnWorker(index));
      }
      _workers.addAll(started);
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

  Future<_NativeSourceWriteWorker> _spawnWorker(int index) async {
    final ready = ReceivePort();
    try {
      final isolate = await Isolate.spawn<List<Object?>>(
        _nativeSourceWriteWorkerEntry,
        <Object?>[ready.sendPort, libPath],
        debugName: 'zic-source-write-$index',
      );
      final value = await ready.first;
      if (value is! SendPort) {
        isolate.kill(priority: Isolate.immediate);
        throw StateError('native source write worker failed to start: $value');
      }
      return _NativeSourceWriteWorker(value, isolate);
    } finally {
      ready.close();
    }
  }

  void _pump() {
    for (final worker in _workers) {
      if (worker.busy || _pending.isEmpty) continue;
      final pending = _takeNextPending();
      if (pending == null) continue;
      worker.busy = true;
      unawaited(_run(worker, pending));
    }
    _notifyIdle();
  }

  _PendingNativeSourceWrite? _takeNextPending() {
    while (_pending.isNotEmpty) {
      var selectedIndex = 0;
      for (var index = 1; index < _pending.length; index++) {
        final candidate = _pending[index];
        final selected = _pending[selectedIndex];
        final candidatePriority = candidate.control?.priority ?? 0;
        final selectedPriority = selected.control?.priority ?? 0;
        if (candidatePriority > selectedPriority ||
            (candidatePriority == selectedPriority &&
                candidate.sequence < selected.sequence)) {
          selectedIndex = index;
        }
      }
      final pending = _pending.removeAt(selectedIndex);
      if (pending.control?.cancelled != true) return pending;
      if (!pending.completer.isCompleted) {
        final control = pending.control!;
        try {
          control.throwIfCancelled();
        } on Object catch (error, stackTrace) {
          pending.completer.completeError(error, stackTrace);
        }
      }
    }
    return null;
  }

  Future<void> _run(
    _NativeSourceWriteWorker worker,
    _PendingNativeSourceWrite pending,
  ) async {
    try {
      final status = await worker.run(pending);
      if (!pending.completer.isCompleted) {
        pending.completer.complete(status);
      }
    } on Object catch (error, stack) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(error, stack);
      }
    } finally {
      worker.busy = false;
      _pump();
    }
  }

  void _notifyIdle() {
    if (_pending.isNotEmpty || _workers.any((worker) => worker.busy)) return;
    final completer = _idleCompleter;
    _idleCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }
}

final class _PendingNativeSourceWrite {
  _PendingNativeSourceWrite({
    required this.operation,
    required this.sourceAddress,
    required this.epoch,
    required this.offset,
    required this.length,
    this.bytes,
    this.path,
    this.fileOffset = 0,
    this.control,
    required this.sequence,
  });

  final _NativeSourceWriteOperation operation;
  final int sourceAddress;
  final int epoch;
  final int offset;
  final int length;
  final TransferableTypedData? bytes;
  final String? path;
  final int fileOffset;
  final TaskControl? control;
  final int sequence;
  final Completer<int> completer = Completer<int>();
}

final class _NativeSourceWriteWorker {
  _NativeSourceWriteWorker(this.port, this.isolate) {
    isolate.addOnExitListener(_exitPort.sendPort);
    _exited = _exitPort.first.then<void>((_) {}).whenComplete(_exitPort.close);
  }

  final SendPort port;
  final Isolate isolate;
  final ReceivePort _exitPort = ReceivePort();
  late final Future<void> _exited;
  bool busy = false;

  Future<int> run(_PendingNativeSourceWrite pending) async {
    final response = ReceivePort();
    try {
      port.send(<Object?>[
        response.sendPort,
        pending.operation.index,
        pending.sourceAddress,
        pending.epoch,
        pending.offset,
        pending.length,
        pending.bytes,
        pending.path,
        pending.fileOffset,
      ]);
      final value = await Future.any<Object?>(<Future<Object?>>[
        response.first,
        _exited.then<Object?>((_) => _sourceWriteWorkerExitedSignal),
      ]);
      if (identical(value, _sourceWriteWorkerExitedSignal)) {
        throw StateError('native source write worker exited before responding');
      }
      if (value is int) return value;
      throw StateError('invalid native source write response: $value');
    } finally {
      response.close();
    }
  }

  Future<void> close() async {
    port.send('close');
    try {
      await _exited.timeout(const Duration(milliseconds: 500));
    } on TimeoutException {
      isolate.kill(priority: Isolate.immediate);
      await _exited;
    }
  }
}

@pragma('vm:entry-point')
void _nativeSourceWriteWorkerEntry(List<Object?> arguments) {
  final ready = arguments[0]! as SendPort;
  final libPath = arguments[1] as String?;
  final receive = ReceivePort();
  late final _SourceApi api;
  try {
    api = _SourceApi(openNativeLib(libPath));
  } on Object catch (error) {
    ready.send('native library load failed: $error');
    receive.close();
    return;
  }
  ready.send(receive.sendPort);
  receive.listen((Object? message) async {
    if (message == 'close') {
      receive.close();
      Isolate.exit();
    }
    if (message is! List<Object?> || message.length < 9) return;
    final reply = message[0]! as SendPort;
    final operation = _NativeSourceWriteOperation.values[message[1]! as int];
    final source = Pointer<_Source>.fromAddress(message[2]! as int);
    final epoch = message[3]! as int;
    final offset = message[4]! as int;
    final length = message[5]! as int;
    try {
      if (operation == _NativeSourceWriteOperation.reserveCapacity) {
        reply.send(api.reserveCapacity(source, epoch, length));
        return;
      }
      if (operation == _NativeSourceWriteOperation.appendFileRange) {
        final path = message[7]! as String;
        final fileOffset = message[8]! as int;
        final outData = calloc<Pointer<Uint8>>();
        RandomAccessFile? file;
        try {
          final reserve = api.reserve(source, epoch, offset, length, outData);
          if (reserve != SourceStatus.ok.index) {
            reply.send(reserve);
            return;
          }
          final destination = outData.value;
          if (destination == nullptr) {
            reply.send(SourceStatus.failed.index);
            return;
          }
          file = await File(path).open(mode: FileMode.read);
          await file.setPosition(fileOffset);
          final target = destination.asTypedList(length);
          var filled = 0;
          while (filled < length) {
            final read = await file.readInto(target, filled, length);
            if (read <= 0) {
              reply.send(SourceStatus.failed.index);
              return;
            }
            filled += read;
          }
          reply.send(api.commit(source, epoch, offset, length));
          return;
        } finally {
          try {
            await file?.close();
          } on Object {
            // Worker-local descriptor cleanup must not replace the source
            // commit result.
          }
          calloc.free(outData);
        }
      }
      final transferred = message[6]! as TransferableTypedData;
      final bytes = transferred.materialize().asUint8List();
      final outData = calloc<Pointer<Uint8>>();
      try {
        final reserve = api.reserve(
          source,
          epoch,
          offset,
          bytes.length,
          outData,
        );
        if (reserve != SourceStatus.ok.index) {
          reply.send(reserve);
          return;
        }
        final destination = outData.value;
        if (destination == nullptr) {
          reply.send(SourceStatus.failed.index);
          return;
        }
        destination.asTypedList(bytes.length).setAll(0, bytes);
        reply.send(api.commit(source, epoch, offset, bytes.length));
      } finally {
        calloc.free(outData);
      }
    } on Object catch (error) {
      reply.send('native source write failed: $error');
    }
  });
}

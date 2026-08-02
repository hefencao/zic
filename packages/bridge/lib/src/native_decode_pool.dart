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
  });

  final int status;
  final int frameAddress;
  final int frameCount;
  final int loopCount;
  final bool metadataComplete;
  final int cycle;
  final int nativeMicros;
}

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
  final Queue<_PendingNativeDecode> _pending = Queue<_PendingNativeDecode>();
  final List<_NativeDecodeWorker> _workers = <_NativeDecodeWorker>[];
  Future<void>? _starting;
  int _owners = 0;
  bool _closeWhenIdle = false;

  void acquire() {
    _owners++;
  }

  void release() {
    if (_owners <= 0) {
      throw StateError('native decode worker pool owner underflow');
    }
    _owners--;
    if (_owners == 0) {
      _requestShutdown();
    }
  }

  Future<_NativeDecodeResult> decode({
    required int cursorAddress,
    required int epoch,
  }) async {
    await _ensureStarted();
    final completer = Completer<_NativeDecodeResult>();
    _pending.addLast(
      _PendingNativeDecode(
        cursorAddress: cursorAddress,
        epoch: epoch,
        completer: completer,
      ),
    );
    _pump();
    return completer.future;
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
      if (value is! SendPort) {
        throw StateError('native decode worker failed to start: $value');
      }
      return _NativeDecodeWorker(value);
    } finally {
      ready.close();
    }
  }

  void _requestShutdown() {
    if (_pending.isNotEmpty || _workers.any((worker) => worker.busy)) {
      _closeWhenIdle = true;
      return;
    }
    _shutdownNow();
  }

  void _shutdownNow() {
    for (final worker in _workers) {
      worker.close();
    }
    _workers.clear();
    _starting = null;
    _closeWhenIdle = false;
  }

  void _pump() {
    for (final worker in _workers) {
      if (worker.busy || _pending.isEmpty) {
        continue;
      }
      final pending = _pending.removeFirst();
      worker.busy = true;
      unawaited(_run(worker, pending));
    }
  }

  Future<void> _run(
    _NativeDecodeWorker worker,
    _PendingNativeDecode pending,
  ) async {
    try {
      final result = await worker.decode(
        cursorAddress: pending.cursorAddress,
        epoch: pending.epoch,
      );
      pending.completer.complete(result);
    } on Object catch (error, stack) {
      pending.completer.completeError(error, stack);
    } finally {
      worker.busy = false;
      _pump();
      if (_closeWhenIdle &&
          _owners == 0 &&
          _pending.isEmpty &&
          !_workers.any((candidate) => candidate.busy)) {
        _shutdownNow();
      }
    }
  }
}

final class _PendingNativeDecode {
  const _PendingNativeDecode({
    required this.cursorAddress,
    required this.epoch,
    required this.completer,
  });

  final int cursorAddress;
  final int epoch;
  final Completer<_NativeDecodeResult> completer;
}

final class _NativeDecodeWorker {
  _NativeDecodeWorker(this.port);

  final SendPort port;
  bool busy = false;

  void close() {
    port.send('close');
  }

  Future<_NativeDecodeResult> decode({
    required int cursorAddress,
    required int epoch,
  }) async {
    final response = ReceivePort();
    try {
      port.send(<Object?>[response.sendPort, cursorAddress, epoch]);
      final value = await response.first;
      if (value is! List<Object?> || value.isEmpty) {
        throw StateError('invalid native decode worker response: $value');
      }
      if (value.first == 'error') {
        throw StateError(
          value.length > 1 ? value[1].toString() : 'decode failed',
        );
      }
      if (value.length < 7) {
        throw StateError('incomplete native decode worker response: $value');
      }
      return _NativeDecodeResult(
        status: value[0]! as int,
        frameAddress: value[1]! as int,
        frameCount: value[2]! as int,
        loopCount: value[3]! as int,
        metadataComplete: value[4] == true,
        cycle: value[5]! as int,
        nativeMicros: value[6]! as int,
      );
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
  ready.send(receive.sendPort);
  receive.listen((Object? message) {
    if (message == 'close') {
      receive.close();
      Isolate.exit();
    }
    if (message is! List<Object?> || message.length < 3) {
      return;
    }
    final reply = message[0]! as SendPort;
    final cursorAddress = message[1]! as int;
    final epoch = message[2]! as int;
    final out = calloc<Pointer<_Frame>>();
    final stopwatch = Stopwatch()..start();
    try {
      out.value = nullptr;
      final cursor = Pointer<_Cursor>.fromAddress(cursorAddress);
      final status = api.decode(cursor, epoch, out);
      final frameAddress = out.value == nullptr ? 0 : out.value.address;
      reply.send(<Object?>[
        status,
        frameAddress,
        api.frameCount(cursor),
        api.loopCount(cursor),
        api.metadataComplete(cursor) != 0,
        api.cycle(cursor),
        stopwatch.elapsedMicroseconds,
      ]);
    } on Object catch (error) {
      final frame = out.value;
      if (frame != nullptr) {
        api.frameRelease(frame);
      }
      reply.send(<Object?>['error', error.toString()]);
    } finally {
      calloc.free(out);
    }
  });
}

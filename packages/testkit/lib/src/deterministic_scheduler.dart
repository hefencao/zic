typedef TaskBody = Future<void> Function();

final class DetTask {
  const DetTask({
    required this.key,
    required this.priority,
    required this.sequence,
    required this.body,
  });

  final String key;
  final int priority;
  final int sequence;
  final TaskBody body;
}

final class DetScheduler {
  final List<DetTask> _queue = <DetTask>[];
  int _sequence = 0;

  int get length => _queue.length;
  bool get isEmpty => _queue.isEmpty;

  void schedule({
    required String key,
    required int priority,
    required TaskBody body,
  }) {
    _queue.removeWhere((task) => task.key == key);
    _queue.add(
      DetTask(
        key: key,
        priority: priority,
        sequence: _sequence++,
        body: body,
      ),
    );
    _queue.sort((a, b) {
      final priorityOrder = b.priority.compareTo(a.priority);
      if (priorityOrder != 0) {
        return priorityOrder;
      }
      return a.sequence.compareTo(b.sequence);
    });
  }

  bool cancel(String key) {
    final previousLength = _queue.length;
    _queue.removeWhere((task) => task.key == key);
    return _queue.length != previousLength;
  }

  Future<bool> runNext() async {
    if (_queue.isEmpty) {
      return false;
    }
    final task = _queue.removeAt(0);
    await task.body();
    return true;
  }

  Future<void> runUntilIdle() async {
    while (await runNext()) {}
  }
}

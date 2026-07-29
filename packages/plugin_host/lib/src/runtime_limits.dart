/// Resource envelope that every ecosystem-specific runtime must enforce.
///
/// The pure-Dart gate can enforce invocation timeout, response bytes and
/// concurrent calls around the transport. Native/JavaScript heap limits still
/// require backend support, so an executor must reject unsupported limits.
final class ExternalPluginRuntimeLimits {
  const ExternalPluginRuntimeLimits({
    this.invocationTimeout = const Duration(seconds: 15),
    this.maxResponseBytes = 16 * 1024 * 1024,
    this.maxConcurrentInvocations = 4,
    this.maxRuntimeHeapBytes = 64 * 1024 * 1024,
  })  : assert(maxResponseBytes > 0),
        assert(maxConcurrentInvocations > 0),
        assert(maxRuntimeHeapBytes > 0);

  final Duration invocationTimeout;
  final int maxResponseBytes;
  final int maxConcurrentInvocations;
  final int maxRuntimeHeapBytes;

  Map<String, Object?> toMessage() => <String, Object?>{
        'invocationTimeoutMicros': invocationTimeout.inMicroseconds,
        'maxResponseBytes': maxResponseBytes,
        'maxConcurrentInvocations': maxConcurrentInvocations,
        'maxRuntimeHeapBytes': maxRuntimeHeapBytes,
      };

  factory ExternalPluginRuntimeLimits.fromMessage(Object? value) {
    if (value is! Map<Object?, Object?> ||
        value.keys.any((key) => key is! String)) {
      throw const FormatException('runtime limits must be an object');
    }
    final message = Map<String, Object?>.from(value);
    const fields = <String>{
      'invocationTimeoutMicros',
      'maxResponseBytes',
      'maxConcurrentInvocations',
      'maxRuntimeHeapBytes',
    };
    if (message.length != fields.length ||
        !message.keys.toSet().containsAll(fields)) {
      throw const FormatException('runtime limits fields are invalid');
    }
    final timeout = message['invocationTimeoutMicros'];
    final response = message['maxResponseBytes'];
    final concurrent = message['maxConcurrentInvocations'];
    final heap = message['maxRuntimeHeapBytes'];
    if (timeout is! int ||
        response is! int ||
        concurrent is! int ||
        heap is! int) {
      throw const FormatException('runtime limits values must be integers');
    }
    final limits = ExternalPluginRuntimeLimits(
      invocationTimeout: Duration(microseconds: timeout),
      maxResponseBytes: response,
      maxConcurrentInvocations: concurrent,
      maxRuntimeHeapBytes: heap,
    );
    limits.validate();
    return limits;
  }

  /// Duration relational operators are not constant expressions on the Dart
  /// SDK range used by zic. Keep the value object const-capable and validate
  /// the duration at the activation boundary instead.
  void validate() {
    if (invocationTimeout <= Duration.zero) {
      throw ArgumentError.value(
        invocationTimeout,
        'invocationTimeout',
        'must be positive',
      );
    }
    if (maxResponseBytes <= 0 ||
        maxConcurrentInvocations <= 0 ||
        maxRuntimeHeapBytes <= 0) {
      throw ArgumentError('external plugin runtime limits must be positive');
    }
  }
}

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

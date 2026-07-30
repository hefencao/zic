import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:catalog/catalog.dart';
import 'package:crypto/crypto.dart';

import 'plugin_contract.dart';
import 'runtime_channel.dart';
import 'runtime_limits.dart';
import 'runtime_worker.dart';

/// Process-entry activation envelope reconstructed from the raw platform wire.
///
/// This value is intentionally independent from [ExternalComicPluginCatalogEntry].
/// The isolated process receives only the immutable identity and resource
/// envelope that was approved by the host; it does not trust or re-read a
/// repository catalog entry.
sealed class ExternalPluginRuntimeActivationEnvelope {
  ExternalPluginRuntimeActivationEnvelope({
    required this.format,
    required this.pluginId,
    required this.pluginVersion,
    required this.payloadPath,
    required this.payloadByteLength,
    required String payloadSha256,
    required Iterable<ExternalPluginCapability> capabilities,
    required this.limits,
  })  : payloadSha256 = payloadSha256.toLowerCase(),
        capabilities = Set<ExternalPluginCapability>.unmodifiable(capabilities) {
    if (pluginId.trim().isEmpty ||
        pluginVersion.trim().isEmpty ||
        payloadPath.trim().isEmpty ||
        payloadByteLength <= 0 ||
        !_sha256Pattern.hasMatch(this.payloadSha256)) {
      throw const FormatException('runtime activation identity is invalid');
    }
    final expectedPrefix = switch (format) {
      ExternalComicPluginFormat.mihonExtension => 'mihon:',
      ExternalComicPluginFormat.veneraJavaScript => 'venera:',
    };
    if (!pluginId.startsWith(expectedPrefix)) {
      throw const FormatException('runtime activation plugin format mismatches id');
    }
    limits.validate();
  }

  static const int schemaVersion = 1;

  final ExternalComicPluginFormat format;
  final String pluginId;
  final String pluginVersion;
  final String payloadPath;
  final int payloadByteLength;
  final String payloadSha256;
  final Set<ExternalPluginCapability> capabilities;
  final ExternalPluginRuntimeLimits limits;

  static ExternalPluginRuntimeActivationEnvelope fromMessage(Object? value) {
    final message = _stringObjectMap(value, 'runtime activation');
    final version = message['schemaVersion'];
    if (version is! int || version != schemaVersion) {
      throw FormatException('unsupported runtime activation schema: $version');
    }
    final formatName = _requiredString(message, 'format');
    final format = _enumByName(
      ExternalComicPluginFormat.values,
      formatName,
      'plugin format',
    );
    final common = _ActivationCommon.fromMessage(message, format);
    return switch (format) {
      ExternalComicPluginFormat.mihonExtension =>
        MihonRuntimeActivationEnvelope._fromMessage(message, common),
      ExternalComicPluginFormat.veneraJavaScript =>
        VeneraRuntimeActivationEnvelope._fromMessage(message, common),
    };
  }
}

final class MihonRuntimeActivationEnvelope
    extends ExternalPluginRuntimeActivationEnvelope {
  MihonRuntimeActivationEnvelope({
    required super.pluginId,
    required super.pluginVersion,
    required super.payloadPath,
    required super.payloadByteLength,
    required super.payloadSha256,
    required super.capabilities,
    required super.limits,
    required this.packageName,
    required String signerSha256,
    required this.versionCode,
    required this.extensionLib,
    required Iterable<String> entryClasses,
  })  : signerSha256 = signerSha256.toLowerCase(),
        entryClasses = List<String>.unmodifiable(entryClasses),
        super(format: ExternalComicPluginFormat.mihonExtension) {
    if (packageName.trim().isEmpty ||
        !_sha256Pattern.hasMatch(this.signerSha256) ||
        versionCode < 0 ||
        extensionLib.trim().isEmpty ||
        this.entryClasses.isEmpty ||
        this.entryClasses.any((value) => value.trim().isEmpty) ||
        this.entryClasses.toSet().length != this.entryClasses.length) {
      throw const FormatException('Mihon runtime activation is incomplete');
    }
  }

  final String packageName;
  final String signerSha256;
  final int versionCode;
  final String extensionLib;
  final List<String> entryClasses;

  factory MihonRuntimeActivationEnvelope._fromMessage(
    Map<String, Object?> message,
    _ActivationCommon common,
  ) {
    _requireExactFields(message, const <String>{
      'schemaVersion',
      'format',
      'pluginId',
      'pluginVersion',
      'payloadPath',
      'payloadByteLength',
      'payloadSha256',
      'packageName',
      'signerSha256',
      'versionCode',
      'extensionLib',
      'entryClasses',
      'capabilities',
      'limits',
    });
    final rawClasses = _objectList(message['entryClasses'], 'entryClasses');
    return MihonRuntimeActivationEnvelope(
      pluginId: common.pluginId,
      pluginVersion: common.pluginVersion,
      payloadPath: common.payloadPath,
      payloadByteLength: common.payloadByteLength,
      payloadSha256: common.payloadSha256,
      capabilities: common.capabilities,
      limits: common.limits,
      packageName: _requiredString(message, 'packageName'),
      signerSha256: _requiredString(message, 'signerSha256'),
      versionCode: _requiredNonNegativeInt(message, 'versionCode'),
      extensionLib: _requiredString(message, 'extensionLib'),
      entryClasses: rawClasses.map(
        (value) => _requiredStringValue(value, 'entry class'),
      ),
    );
  }
}

final class VeneraRuntimeActivationEnvelope
    extends ExternalPluginRuntimeActivationEnvelope {
  VeneraRuntimeActivationEnvelope({
    required super.pluginId,
    required super.pluginVersion,
    required super.payloadPath,
    required super.payloadByteLength,
    required super.payloadSha256,
    required super.capabilities,
    required super.limits,
    required this.sourceKey,
  }) : super(format: ExternalComicPluginFormat.veneraJavaScript) {
    if (sourceKey.trim().isEmpty) {
      throw const FormatException('Venera runtime source key is empty');
    }
  }

  final String sourceKey;

  factory VeneraRuntimeActivationEnvelope._fromMessage(
    Map<String, Object?> message,
    _ActivationCommon common,
  ) {
    _requireExactFields(message, const <String>{
      'schemaVersion',
      'format',
      'pluginId',
      'pluginVersion',
      'payloadPath',
      'payloadByteLength',
      'payloadSha256',
      'sourceKey',
      'capabilities',
      'limits',
    });
    return VeneraRuntimeActivationEnvelope(
      pluginId: common.pluginId,
      pluginVersion: common.pluginVersion,
      payloadPath: common.payloadPath,
      payloadByteLength: common.payloadByteLength,
      payloadSha256: common.payloadSha256,
      capabilities: common.capabilities,
      limits: common.limits,
      sourceKey: _requiredString(message, 'sourceKey'),
    );
  }
}

/// One process-private payload copy whose bytes were validated against the
/// host-approved inspection identity.
///
/// Drivers receive this path instead of the original host path, closing the
/// verify-then-reopen race. The process host owns deletion after the runtime
/// session has fully stopped.
final class ExternalPluginRuntimeVerifiedPayload {
  ExternalPluginRuntimeVerifiedPayload({
    required this.path,
    required this.byteLength,
    required String sha256,
  }) : sha256 = sha256.toLowerCase() {
    if (path.trim().isEmpty ||
        byteLength <= 0 ||
        !_sha256Pattern.hasMatch(this.sha256)) {
      throw ArgumentError('verified plugin payload identity is invalid');
    }
  }

  final String path;
  final int byteLength;
  final String sha256;
  bool _disposed = false;

  Future<void> _dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final file = File(path);
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // Runtime teardown must not resurrect or replay a plugin request merely
      // because process-cache cleanup failed. The app cache remains eligible
      // for ordinary platform cache maintenance.
    }
  }
}

/// Revalidates and atomically stages an inspected payload inside the isolated
/// process before a class-loader or JavaScript engine is allowed to see it.
abstract interface class ExternalPluginRuntimePayloadVerifier {
  Future<ExternalPluginRuntimeVerifiedPayload> verify(
    ExternalPluginRuntimeActivationEnvelope activation,
  );
}

final class FileExternalPluginRuntimePayloadVerifier
    implements ExternalPluginRuntimePayloadVerifier {
  FileExternalPluginRuntimePayloadVerifier({
    Directory? verifiedDirectory,
    this.maxPayloadBytes = 256 * 1024 * 1024,
  })  : verifiedDirectory = verifiedDirectory ?? Directory.systemTemp,
        assert(maxPayloadBytes > 0);

  final Directory verifiedDirectory;
  final int maxPayloadBytes;

  @override
  Future<ExternalPluginRuntimeVerifiedPayload> verify(
    ExternalPluginRuntimeActivationEnvelope activation,
  ) async {
    if (activation.payloadByteLength > maxPayloadBytes) {
      throw const ExternalPluginRuntimeProcessException(
        code: 'payload-too-large',
        message: 'plugin payload exceeds isolated runtime limit',
      );
    }
    final sourcePath = activation.payloadPath;
    try {
      final type = await FileSystemEntity.type(
        sourcePath,
        followLinks: false,
      );
      if (type != FileSystemEntityType.file) {
        throw const ExternalPluginRuntimeProcessException(
          code: 'payload-unavailable',
          message: 'plugin payload is not a regular immutable file',
        );
      }
      await verifiedDirectory.create(recursive: true);
    } on ExternalPluginRuntimeProcessException {
      rethrow;
    } on FileSystemException {
      throw const ExternalPluginRuntimeProcessException(
        code: 'payload-unavailable',
        message: 'plugin payload path is unavailable in isolated runtime',
      );
    }
    final token = _randomToken();
    final prefix = '.zic-${activation.format.name}-$token';
    final temporary = File.fromUri(
      verifiedDirectory.uri.resolve('$prefix.part'),
    );
    final promoted = File.fromUri(
      verifiedDirectory.uri.resolve('$prefix.payload'),
    );
    RandomAccessFile? output;
    try {
      final source = File(sourcePath);
      final before = await source.stat();
      if (before.size != activation.payloadByteLength) {
        throw const ExternalPluginRuntimeProcessException(
          code: 'payload-changed',
          message: 'plugin payload length changed before activation',
        );
      }

      var copied = 0;
      final digestSink = _SingleDigestSink();
      final digestInput = sha256.startChunkedConversion(digestSink);
      output = await temporary.open(mode: FileMode.write);
      await for (final chunk in source.openRead()) {
        copied += chunk.length;
        if (copied > activation.payloadByteLength || copied > maxPayloadBytes) {
          throw const ExternalPluginRuntimeProcessException(
            code: 'payload-changed',
            message: 'plugin payload grew while being staged',
          );
        }
        digestInput.add(chunk);
        await output.writeFrom(chunk);
      }
      digestInput.close();
      await output.flush();
      await output.close();
      output = null;

      if (copied != activation.payloadByteLength) {
        throw const ExternalPluginRuntimeProcessException(
          code: 'payload-changed',
          message: 'plugin payload length changed while being staged',
        );
      }
      final actualDigest = digestSink.single.toString().toLowerCase();
      if (actualDigest != activation.payloadSha256) {
        throw const ExternalPluginRuntimeProcessException(
          code: 'payload-identity-mismatch',
          message: 'plugin payload hash does not match approved inspection',
        );
      }
      await temporary.rename(promoted.path);
      return ExternalPluginRuntimeVerifiedPayload(
        path: promoted.path,
        byteLength: copied,
        sha256: actualDigest,
      );
    } on ExternalPluginRuntimeProcessException {
      rethrow;
    } on FileSystemException {
      throw const ExternalPluginRuntimeProcessException(
        code: 'payload-unavailable',
        message: 'plugin payload could not be staged in isolated runtime',
      );
    } finally {
      final pendingOutput = output;
      if (pendingOutput != null) {
        try {
          await pendingOutput.close();
        } on FileSystemException {
          // Preserve the verification failure while still attempting cleanup.
        }
      }
      try {
        if (await temporary.exists()) {
          await temporary.delete();
        }
      } on FileSystemException {
        // Best-effort cleanup of a failed partial copy.
      }
    }
  }
}

/// Creates one ecosystem-specific driver after process-entry verification.
abstract interface class ExternalPluginRuntimeDriverFactory {
  ExternalComicPluginFormat get format;

  bool supportsLimits(ExternalPluginRuntimeLimits limits);

  Future<ExternalPluginRuntimeDriver> create(
    ExternalPluginRuntimeActivationEnvelope activation,
    ExternalPluginRuntimeVerifiedPayload payload,
  );
}

final class ExternalPluginRuntimeProcessException implements Exception {
  const ExternalPluginRuntimeProcessException({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;

  @override
  String toString() => 'ExternalPluginRuntimeProcessException($code)';
}

final class ExternalPluginRuntimeProcessActivation {
  const ExternalPluginRuntimeProcessActivation({
    required this.sessionId,
    required this.handshake,
  });

  final String sessionId;
  final ExternalPluginRuntimeHandshake handshake;

  Map<String, Object?> toMessage() => <String, Object?>{
        'sessionId': sessionId,
        'handshake': handshake.toMessage(),
      };
}

/// Service-side owner for isolated runtime sessions.
///
/// A process restart creates a new instance with an empty registry. Failed or
/// interrupted catalog requests are never replayed automatically; callers must
/// activate a fresh session and issue a fresh request identity.
final class ExternalPluginRuntimeProcessHost {
  ExternalPluginRuntimeProcessHost({
    required Iterable<ExternalPluginRuntimeDriverFactory> factories,
    ExternalPluginRuntimePayloadVerifier? payloadVerifier,
    String Function(ExternalPluginRuntimeActivationEnvelope activation)?
        sessionIdFactory,
    this.maxActiveSessions = 8,
  })  : _payloadVerifier =
            payloadVerifier ?? FileExternalPluginRuntimePayloadVerifier(),
        _sessionIdFactory = sessionIdFactory ?? _newSessionId,
        _factories = _indexFactories(factories) {
    if (maxActiveSessions <= 0) {
      throw ArgumentError.value(maxActiveSessions, 'maxActiveSessions');
    }
  }

  final Map<ExternalComicPluginFormat, ExternalPluginRuntimeDriverFactory>
      _factories;
  final ExternalPluginRuntimePayloadVerifier _payloadVerifier;
  final String Function(ExternalPluginRuntimeActivationEnvelope activation)
      _sessionIdFactory;
  final int maxActiveSessions;
  final Map<String, _ProcessRuntimeSession> _sessions =
      <String, _ProcessRuntimeSession>{};
  final Map<String, Future<void>> _closingSessions = <String, Future<void>>{};

  bool _closing = false;
  Future<void> _activationTail = Future<void>.value();
  Future<void>? _closeFuture;

  int get activeSessionCount => _sessions.length;

  Future<ExternalPluginRuntimeProcessActivation> activate(
    Object? activationMessage,
  ) {
    if (_closing) {
      return Future<ExternalPluginRuntimeProcessActivation>.error(
        const ExternalPluginRuntimeProcessException(
          code: 'process-closing',
          message: 'isolated runtime process is closing',
        ),
      );
    }
    final activation = _activationTail.then(
      (_) => _activate(activationMessage),
    );
    _activationTail = activation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return activation;
  }

  Future<ExternalPluginRuntimeProcessActivation> _activate(
    Object? activationMessage,
  ) async {
    if (_closing) {
      throw const ExternalPluginRuntimeProcessException(
        code: 'process-closing',
        message: 'isolated runtime process is closing',
      );
    }
    if (_sessions.length + _closingSessions.length >= maxActiveSessions) {
      throw const ExternalPluginRuntimeProcessException(
        code: 'session-limit',
        message: 'isolated runtime session limit reached',
      );
    }
    final activation =
        ExternalPluginRuntimeActivationEnvelope.fromMessage(activationMessage);
    final factory = _factories[activation.format];
    if (factory == null) {
      throw const ExternalPluginRuntimeProcessException(
        code: 'driver-unavailable',
        message: 'plugin runtime driver is unavailable',
      );
    }
    if (!factory.supportsLimits(activation.limits)) {
      throw const ExternalPluginRuntimeProcessException(
        code: 'limits-unsupported',
        message: 'plugin runtime cannot enforce requested limits',
      );
    }

    final payload = await _payloadVerifier.verify(activation);
    ExternalPluginRuntimeDriver? driver;
    ExternalPluginRuntimeWorker? worker;
    try {
      _throwIfClosing();
      driver = await factory.create(activation, payload);
      worker = ExternalPluginRuntimeWorker(driver: driver);
      _throwIfClosing();
      if (activation case VeneraRuntimeActivationEnvelope(:final sourceKey)) {
        final discovered = worker.handshake.sources
            .where((source) => source.externalId == sourceKey)
            .length;
        if (discovered != 1) {
          throw const ExternalPluginRuntimeProcessException(
            code: 'source-identity-mismatch',
            message: 'Venera runtime did not expose the inspected source key',
          );
        }
      }
      final sessionId = _allocateSessionId(activation);
      _sessions[sessionId] = _ProcessRuntimeSession(
        worker: worker,
        payload: payload,
      );
      return ExternalPluginRuntimeProcessActivation(
        sessionId: sessionId,
        handshake: worker.handshake,
      );
    } on Object {
      try {
        if (worker != null) {
          await worker.close();
        } else if (driver != null) {
          await driver.close();
        }
      } on Object {
        // Preserve the activation error; cleanup failure cannot make an
        // untrusted runtime appear successfully activated.
      }
      await payload._dispose();
      rethrow;
    }
  }

  void _throwIfClosing() {
    if (_closing) {
      throw const ExternalPluginRuntimeProcessException(
        code: 'process-closing',
        message: 'isolated runtime process is closing',
      );
    }
  }

  Future<Object?> invoke(String sessionId, Object? requestMessage) {
    if (_closing) {
      throw const ExternalPluginRuntimeProcessException(
        code: 'process-closing',
        message: 'isolated runtime process is closing',
      );
    }
    final session = _session(sessionId);
    return session.worker.handle(requestMessage);
  }

  Future<void> cancel(String sessionId, String requestId) {
    final session = _session(sessionId);
    return session.worker.cancel(requestId);
  }

  Future<void> closeSession(String sessionId) {
    if (sessionId.trim().isEmpty) {
      throw ArgumentError.value(sessionId, 'sessionId');
    }
    final existing = _closingSessions[sessionId];
    if (existing != null) {
      return existing;
    }
    final session = _sessions.remove(sessionId);
    if (session == null) {
      throw const ExternalPluginRuntimeProcessException(
        code: 'session-missing',
        message: 'isolated runtime session is not active',
      );
    }
    late final Future<void> closing;
    closing = session.close().whenComplete(() {
      if (identical(_closingSessions[sessionId], closing)) {
        _closingSessions.remove(sessionId);
      }
    });
    _closingSessions[sessionId] = closing;
    return closing;
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    await _activationTail;
    final sessions = _sessions.values.toList(growable: false);
    _sessions.clear();
    final closing = <Future<void>>[
      ..._closingSessions.values,
      ...sessions.map((session) => session.close()),
    ];
    await Future.wait<void>(closing);
  }

  _ProcessRuntimeSession _session(String sessionId) {
    if (sessionId.trim().isEmpty) {
      throw ArgumentError.value(sessionId, 'sessionId');
    }
    final session = _sessions[sessionId];
    if (session == null) {
      throw const ExternalPluginRuntimeProcessException(
        code: 'session-missing',
        message: 'isolated runtime session is not active',
      );
    }
    return session;
  }

  String _allocateSessionId(
    ExternalPluginRuntimeActivationEnvelope activation,
  ) {
    for (var attempt = 0; attempt < 8; attempt++) {
      final value = _sessionIdFactory(activation).trim();
      if (value.isEmpty) {
        throw const ExternalPluginRuntimeProcessException(
          code: 'invalid-session-id',
          message: 'runtime session id factory returned an empty value',
        );
      }
      if (!_sessions.containsKey(value) &&
          !_closingSessions.containsKey(value)) {
        return value;
      }
    }
    throw const ExternalPluginRuntimeProcessException(
      code: 'session-id-collision',
      message: 'could not allocate a unique runtime session identity',
    );
  }
}

final class _ProcessRuntimeSession {
  _ProcessRuntimeSession({required this.worker, required this.payload});

  final ExternalPluginRuntimeWorker worker;
  final ExternalPluginRuntimeVerifiedPayload payload;
  Future<void>? _closeFuture;

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    Object? workerError;
    StackTrace? workerStackTrace;
    try {
      await worker.close();
    } on Object catch (error, stackTrace) {
      workerError = error;
      workerStackTrace = stackTrace;
    } finally {
      await payload._dispose();
    }
    if (workerError != null) {
      Error.throwWithStackTrace(workerError, workerStackTrace!);
    }
  }
}

final class _ActivationCommon {
  const _ActivationCommon({
    required this.pluginId,
    required this.pluginVersion,
    required this.payloadPath,
    required this.payloadByteLength,
    required this.payloadSha256,
    required this.capabilities,
    required this.limits,
  });

  final String pluginId;
  final String pluginVersion;
  final String payloadPath;
  final int payloadByteLength;
  final String payloadSha256;
  final Set<ExternalPluginCapability> capabilities;
  final ExternalPluginRuntimeLimits limits;

  factory _ActivationCommon.fromMessage(
    Map<String, Object?> message,
    ExternalComicPluginFormat format,
  ) {
    final rawCapabilities =
        _objectList(message['capabilities'], 'capabilities');
    final capabilities = rawCapabilities
        .map((value) => _enumByName(
              ExternalPluginCapability.values,
              _requiredStringValue(value, 'capability'),
              'capability',
            ))
        .toSet();
    if (capabilities.length != rawCapabilities.length) {
      throw const FormatException('runtime capabilities contain duplicates');
    }
    final pluginId = _requiredString(message, 'pluginId');
    final expectedPrefix = switch (format) {
      ExternalComicPluginFormat.mihonExtension => 'mihon:',
      ExternalComicPluginFormat.veneraJavaScript => 'venera:',
    };
    if (!pluginId.startsWith(expectedPrefix)) {
      throw const FormatException('runtime plugin identity format is invalid');
    }
    return _ActivationCommon(
      pluginId: pluginId,
      pluginVersion: _requiredString(message, 'pluginVersion'),
      payloadPath: _requiredString(message, 'payloadPath'),
      payloadByteLength: _requiredPositiveInt(message, 'payloadByteLength'),
      payloadSha256: _requiredString(message, 'payloadSha256'),
      capabilities: capabilities,
      limits: ExternalPluginRuntimeLimits.fromMessage(message['limits']),
    );
  }
}

Map<ExternalComicPluginFormat, ExternalPluginRuntimeDriverFactory>
    _indexFactories(Iterable<ExternalPluginRuntimeDriverFactory> factories) {
  final result = <ExternalComicPluginFormat, ExternalPluginRuntimeDriverFactory>{};
  for (final factory in factories) {
    if (result.containsKey(factory.format)) {
      throw ArgumentError('duplicate runtime driver factory: ${factory.format}');
    }
    result[factory.format] = factory;
  }
  return Map<ExternalComicPluginFormat, ExternalPluginRuntimeDriverFactory>
      .unmodifiable(result);
}

String _newSessionId(ExternalPluginRuntimeActivationEnvelope activation) =>
    '${activation.format.name}-${_randomToken()}';

final class _SingleDigestSink implements Sink<Digest> {
  Digest? _value;
  bool _closed = false;

  Digest get single {
    final value = _value;
    if (!_closed || value == null) {
      throw StateError('plugin payload digest was not finalized');
    }
    return value;
  }

  @override
  void add(Digest data) {
    if (_closed) {
      throw StateError('plugin payload digest sink is closed');
    }
    if (_value != null) {
      throw StateError('plugin payload digest emitted more than once');
    }
    _value = data;
  }

  @override
  void close() {
    _closed = true;
  }
}

String _randomToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
}

final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

Map<String, Object?> _stringObjectMap(Object? value, String label) {
  if (value is! Map<Object?, Object?> || value.keys.any((key) => key is! String)) {
    throw FormatException('$label must be an object');
  }
  return Map<String, Object?>.from(value);
}

List<Object?> _objectList(Object? value, String label) {
  if (value is! List<Object?>) {
    throw FormatException('$label must be a list');
  }
  return value;
}

String _requiredString(Map<String, Object?> message, String field) =>
    _requiredStringValue(message[field], field);

String _requiredStringValue(Object? value, String label) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$label must be a non-empty string');
  }
  return value.trim();
}

int _requiredPositiveInt(Map<String, Object?> message, String field) {
  final value = message[field];
  if (value is! int || value <= 0) {
    throw FormatException('$field must be a positive integer');
  }
  return value;
}

int _requiredNonNegativeInt(Map<String, Object?> message, String field) {
  final value = message[field];
  if (value is! int || value < 0) {
    throw FormatException('$field must be a non-negative integer');
  }
  return value;
}

T _enumByName<T extends Enum>(List<T> values, String name, String label) {
  for (final value in values) {
    if (value.name == name) {
      return value;
    }
  }
  throw FormatException('unknown $label: $name');
}

void _requireExactFields(Map<String, Object?> message, Set<String> fields) {
  if (message.length != fields.length ||
      !message.keys.toSet().containsAll(fields)) {
    throw const FormatException('runtime activation fields are invalid');
  }
}

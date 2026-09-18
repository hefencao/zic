import 'dart:async';

import 'package:catalog/catalog.dart';

import 'plugin_contract.dart';

/// Owns activated external plugin sessions and prevents source identities from
/// being registered by more than one runtime at a time.
final class ExternalPluginRuntimeRegistry {
  ExternalPluginRuntimeRegistry(Iterable<ExternalComicPluginHost> hosts) {
    for (final host in hosts) {
      final previous = _hosts[host.format];
      if (previous != null) {
        throw ArgumentError(
          'multiple external plugin hosts registered for ${host.format.name}',
        );
      }
      _hosts[host.format] = host;
    }
  }

  final Map<ExternalComicPluginFormat, ExternalComicPluginHost> _hosts =
      <ExternalComicPluginFormat, ExternalComicPluginHost>{};
  final Map<String, ExternalComicPluginSession> _sessions =
      <String, ExternalComicPluginSession>{};
  final Map<String, Future<List<BrowsableComicSource>>> _activations =
      <String, Future<List<BrowsableComicSource>>>{};
  Future<void> _commitTail = Future<void>.value();
  Future<void>? _closeFuture;
  final Map<String, String> _sourceOwners = <String, String>{};
  bool _closed = false;

  Iterable<String> get activePluginIds =>
      List<String>.unmodifiable(_sessions.keys);

  List<BrowsableComicSource> get activeSources =>
      List<BrowsableComicSource>.unmodifiable(
        _sessions.values.expand((session) => session.sources),
      );

  bool isActive(String pluginId) => _sessions.containsKey(pluginId);

  String? ownerOfSource(String sourceId) => _sourceOwners[sourceId];

  Future<List<BrowsableComicSource>> activate(
    ExternalComicPluginCatalogEntry plugin,
  ) async {
    _requireOpen();
    final existing = _sessions[plugin.pluginId];
    if (existing != null) {
      return List<BrowsableComicSource>.unmodifiable(existing.sources);
    }
    final pending = _activations[plugin.pluginId];
    if (pending != null) {
      return pending;
    }
    final future = _activate(plugin);
    _activations[plugin.pluginId] = future;
    try {
      return await future;
    } finally {
      if (identical(_activations[plugin.pluginId], future)) {
        _activations.remove(plugin.pluginId);
      }
    }
  }

  Future<List<BrowsableComicSource>> replace(
    ExternalComicPluginCatalogEntry plugin,
  ) async {
    _requireOpen();
    final existing = _sessions[plugin.pluginId];
    if (existing == null) return activate(plugin);
    final pending = _activations[plugin.pluginId];
    if (pending != null) return pending;
    final future = _replace(plugin, existing);
    _activations[plugin.pluginId] = future;
    try {
      return await future;
    } finally {
      if (identical(_activations[plugin.pluginId], future)) {
        _activations.remove(plugin.pluginId);
      }
    }
  }

  Future<List<BrowsableComicSource>> _activate(
    ExternalComicPluginCatalogEntry plugin,
  ) {
    final candidate = _activateCandidate(plugin);
    return candidate.then<List<BrowsableComicSource>>((session) async {
      final committed = _enqueueCommit<List<BrowsableComicSource>>(() {
        // Only this synchronous state transition is serialized. Waiting for
        // candidate activation here would make a slow plugin block every
        // already-finished candidate behind it.
        _validateCandidate(plugin, session);
        _installSession(plugin.pluginId, session);
        return List<BrowsableComicSource>.unmodifiable(session.sources);
      });
      try {
        return await committed;
      } on Object {
        await session.close();
        rethrow;
      }
    });
  }

  Future<List<BrowsableComicSource>> _replace(
    ExternalComicPluginCatalogEntry plugin,
    ExternalComicPluginSession existing,
  ) {
    // Activate and validate the replacement while the old session remains
    // authoritative. A transient activation failure must never remove a
    // previously working imported plugin/source from the App.
    final candidate = _activateCandidate(
      plugin,
      replacingPluginId: plugin.pluginId,
    );
    return candidate.then<List<BrowsableComicSource>>((replacement) async {
      final committed = _enqueueCommit<List<BrowsableComicSource>>(() {
        // Keep the old session authoritative until this short synchronous
        // commit succeeds. Its asynchronous close is deliberately outside
        // the registry commit lane so a slow teardown cannot stall another
        // plugin activation.
        _validateCandidate(
          plugin,
          replacement,
          replacingPluginId: plugin.pluginId,
        );
        if (!identical(_sessions[plugin.pluginId], existing)) {
          throw StateError(
            'external plugin runtime session changed during replacement',
          );
        }

        for (final source in existing.sources) {
          if (_sourceOwners[source.sourceId] == plugin.pluginId) {
            _sourceOwners.remove(source.sourceId);
          }
        }
        _installSession(plugin.pluginId, replacement);
        return List<BrowsableComicSource>.unmodifiable(replacement.sources);
      });
      try {
        final sources = await committed;
        try {
          await existing.close();
        } on Object {
          // The new validated session is already authoritative. A retired-
          // session cleanup failure must not roll back to a runtime that is
          // being closed.
        }
        return sources;
      } on Object {
        await replacement.close();
        rethrow;
      }
    });
  }

  Future<ExternalComicPluginSession> _activateCandidate(
    ExternalComicPluginCatalogEntry plugin, {
    String? replacingPluginId,
  }) async {
    final host = _hosts[plugin.format];
    if (host == null) {
      throw ExternalPluginActivationException(
        pluginId: plugin.pluginId,
        denials: const <ExternalPluginDenial>{
          ExternalPluginDenial.hostUnavailable,
        },
      );
    }

    final session = await host.activate(plugin);
    try {
      _validateCandidate(
        plugin,
        session,
        replacingPluginId: replacingPluginId,
      );
      return session;
    } on Object {
      await session.close();
      rethrow;
    }
  }

  void _validateCandidate(
    ExternalComicPluginCatalogEntry plugin,
    ExternalComicPluginSession session, {
    String? replacingPluginId,
  }) {
    if (_closed) {
      throw StateError('external plugin runtime registry is closed');
    }
    final sourcePrefix = switch (plugin.format) {
      ExternalComicPluginFormat.mihonExtension => 'mihon:',
      ExternalComicPluginFormat.veneraJavaScript => 'venera:',
    };
    if (session.plugin.pluginId != plugin.pluginId ||
        session.plugin.format != plugin.format ||
        session.sources.isEmpty ||
        session.sources.any(
          (source) => !source.sourceId.startsWith(sourcePrefix),
        )) {
      throw ExternalPluginActivationException(
        pluginId: plugin.pluginId,
        denials: const <ExternalPluginDenial>{
          ExternalPluginDenial.sourceIdentityMismatch,
        },
      );
    }
    final sourceIds = session.sources.map((source) => source.sourceId).toList();
    final uniqueSourceIds = sourceIds.toSet();
    if (uniqueSourceIds.length != sourceIds.length) {
      throw ExternalPluginActivationException(
        pluginId: plugin.pluginId,
        denials: const <ExternalPluginDenial>{
          ExternalPluginDenial.sourceIdentityMismatch,
        },
      );
    }
    final collisions = uniqueSourceIds.where((sourceId) {
      final owner = _sourceOwners[sourceId];
      return owner != null && owner != replacingPluginId;
    }).toSet();
    if (collisions.isNotEmpty) {
      throw ExternalPluginActivationException(
        pluginId: plugin.pluginId,
        denials: const <ExternalPluginDenial>{
          ExternalPluginDenial.sourceIdentityCollision,
        },
        cause: StateError(
          'source identities already active: ${collisions.join(', ')}',
        ),
      );
    }
  }

  Future<T> _enqueueCommit<T>(FutureOr<T> Function() operation) {
    final previous = _commitTail;
    late final Future<T> committed;
    committed = previous.then<T>((_) => operation());
    _commitTail = committed.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return committed;
  }

  void _installSession(String pluginId, ExternalComicPluginSession session) {
    _sessions[pluginId] = session;
    for (final source in session.sources) {
      _sourceOwners[source.sourceId] = pluginId;
    }
  }

  Future<void> deactivate(String pluginId) async {
    _requireOpen();
    final pending = _activations[pluginId];
    if (pending != null) {
      try {
        await pending;
      } on Object {
        // A failed activation/replacement can leave the previous session
        // authoritative. Deactivation/removal must still close that session.
      }
    }
    final session = _sessions[pluginId];
    if (session == null) {
      return;
    }
    await session.close();
    _sessions.remove(pluginId);
    for (final source in session.sources) {
      if (_sourceOwners[source.sourceId] == pluginId) {
        _sourceOwners.remove(source.sourceId);
      }
    }
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    final pending = _activations.values.toList(growable: false);
    if (pending.isNotEmpty) {
      await Future.wait<void>(
        pending.map((future) async {
          try {
            await future;
          } on Object {
            // The activating caller retains its error; close only drains work.
          }
        }),
      );
    }
    _activations.clear();
    final sessions = _sessions.values.toList(growable: false);
    _sessions.clear();
    _sourceOwners.clear();
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final session in sessions) {
      try {
        await session.close();
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  void _requireOpen() {
    if (_closed) {
      throw StateError('external plugin runtime registry is closed');
    }
  }
}

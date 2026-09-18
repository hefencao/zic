import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:plugin_host/plugin_host.dart';
import 'android_mihon_metadata_reader.dart';
import 'external_plugin_mutation_gate.dart';
import 'method_channel_runtime_backends.dart';

final class ExternalPluginInstallPreview {
  const ExternalPluginInstallPreview({
    required this.plugin,
    required this.inspection,
    required this.repository,
  }) : _claim = null;

  ExternalPluginInstallPreview._claimed(
    this._claim, {
    required this.plugin,
    required this.inspection,
    required this.repository,
  });

  final ExternalComicPluginCatalogEntry plugin;
  final ExternalPluginInspection inspection;
  final Uri repository;
  final Object? _claim;
}

final class _PendingPluginPayload {
  const _PendingPluginPayload(this.path, this.claim);

  final String path;
  final Object claim;
}

final class InstalledExternalPlugin {
  const InstalledExternalPlugin({
    required this.plugin,
    required this.payloadPath,
    required this.payloadSha256,
    required this.repositoryOrigin,
    this.packageName,
    this.signerSha256,
    this.versionCode,
    this.extensionLib,
    this.entryClasses = const <String>[],
    this.sourceKey,
    this.sourceIds = const <String>[],
  });

  final ExternalComicPluginCatalogEntry plugin;
  final String payloadPath;
  final String payloadSha256;
  final String repositoryOrigin;
  final String? packageName;
  final String? signerSha256;
  final int? versionCode;
  final String? extensionLib;
  final List<String> entryClasses;
  final String? sourceKey;

  /// External source identities discovered at the last successful activation.
  ///
  /// Repository metadata does not describe device-imported Mihon sources, so
  /// per-source user settings (for example download directories) persist this
  /// runtime fact instead of re-deriving it.
  final List<String> sourceIds;
}

/// App-shell owner for external repository discovery, immutable payload files,
/// user-pinned trust and activated source sessions.
///
/// Reader, download and cache services only see the returned ordinary
/// [BrowsableComicSource] adapters. Executable payloads remain owned by
/// plugin_host and its dedicated Android process.
final class ExternalPluginController {
  ExternalPluginController._({
    required this.storageRoot,
    this.userAgentProvider,
    required this.discoverDeviceMihonExtensions,
  });

  final String storageRoot;
  final String Function()? userAgentProvider;
  final bool discoverDeviceMihonExtensions;
  late final Directory _root = Directory('$storageRoot/external_plugins');
  late final File _manifest = File('${_root.path}/installed.json');
  final Map<String, InstalledExternalPlugin> _installed =
      <String, InstalledExternalPlugin>{};
  final Map<String, _PendingPluginPayload> _pendingPayloads =
      <String, _PendingPluginPayload>{};
  final Map<String, Object> _previewGenerations = <String, Object>{};
  final Map<String, Object> _activationFailures = <String, Object>{};
  final Map<String, Object> _manifestRestoreFailures = <String, Object>{};
  final StreamController<void> _sourceChanges =
      StreamController<void>.broadcast();
  // Repository/install traffic is plugin-management control-plane I/O, not
  // Reader media data-plane work. Keep its socket lifetime under this owner
  // instead of borrowing the composition NetLane or letting a local client
  // survive controller teardown.
  final Set<HttpClient> _activeRepositoryClients = <HttpClient>{};
  late final ExternalPluginPayloadLoader _payloads =
      CallbackExternalPluginPayloadLoader(_acquirePinnedPayload);
  late final MihonApkInspector _mihonInspector = MihonApkInspector(
    payloads: _payloads,
    metadata: const AndroidMihonApkMetadataReader(),
  );
  late final VeneraJavaScriptInspector _veneraInspector =
      VeneraJavaScriptInspector(payloads: _payloads);
  static const AndroidMihonApkMetadataReader _androidMihonMetadata =
      AndroidMihonApkMetadataReader();
  List<InstalledMihonExtension> _deviceMihonExtensions =
      const <InstalledMihonExtension>[];
  InstalledMihonScan _deviceMihonScan = const InstalledMihonScan.empty();
  Object? _deviceMihonDiscoveryError;
  late final ExternalPluginRuntimeRegistry _registry =
      ExternalPluginRuntimeRegistry(<ExternalComicPluginHost>[
    _PinnedExternalPluginHost(
      format: ExternalComicPluginFormat.mihonExtension,
      inspectRecord: _inspectInstalledRecord,
      executor: MihonIsolatedExecutor(
        backend: AndroidMihonIsolatedRuntimeBackend(),
      ),
      recordFor: _installedRecord,
    ),
    _PinnedExternalPluginHost(
      format: ExternalComicPluginFormat.veneraJavaScript,
      inspectRecord: _inspectInstalledRecord,
      executor: VeneraSandboxExecutor(
        backend: AndroidVeneraSandboxRuntimeBackend(),
      ),
      recordFor: _installedRecord,
    ),
  ]);
  Future<void>? _ready;
  Future<void>? _closeFuture;
  Future<void> _manifestWriteTail = Future<void>.value();
  final ExternalPluginMutationGate _durableMutations =
      ExternalPluginMutationGate();
  bool _closed = false;

  static Future<ExternalPluginController> open(
    String storageRoot, {
    String Function()? userAgentProvider,
  }) async {
    final controller = await openDeferred(
      storageRoot,
      userAgentProvider: userAgentProvider,
    );
    await controller.ready;
    return controller;
  }

  /// Reports whether a recoverable manifest may exist without creating the
  /// external-plugin directory or activating any installed runtime.
  static Future<bool> hasDurableManifest(String storageRoot) async {
    const suffixes = <String>[
      '',
      '.part',
      '.bak',
      '.invalid',
    ];
    final manifestPath = '$storageRoot/external_plugins/installed.json';
    for (final suffix in suffixes) {
      if (await File('$manifestPath$suffix').exists()) {
        return true;
      }
    }
    return false;
  }

  /// Opens the controller's durable manifest without activating installed
  /// runtimes. Activation continues in [ready] so optional plugin work cannot
  /// delay the first Home projection.
  static Future<ExternalPluginController> openDeferred(
    String storageRoot, {
    String Function()? userAgentProvider,
    bool discoverDeviceMihonExtensions = true,
    bool deferRuntimeActivation = false,
  }) async {
    final controller = ExternalPluginController._(
      storageRoot: storageRoot,
      userAgentProvider: userAgentProvider,
      discoverDeviceMihonExtensions: discoverDeviceMihonExtensions,
    );
    await controller._prepare();
    if (!deferRuntimeActivation) {
      unawaited(controller._ensureAllActivated());
    }
    return controller;
  }

  /// Completes after optional device extension discovery and installed plugin
  /// activation have finished. Individual activation failures are retained in
  /// [activationFailures], matching the eager-open behavior.
  Future<void> get ready => _ensureAllActivated();

  Future<void> _ensureAllActivated() =>
      _ready ??= _initializeInBackground();

  /// Activates only the installed runtime known to own [sourceId].
  ///
  /// Home/Reader exact-source demand uses this path so one uncached cover or
  /// page does not wake every installed plugin runtime. Source management can
  /// still await [ready] when it explicitly needs the complete projection.
  /// Returns whether the requested source is active after the attempt.
  Future<bool> ensureSourceActive(String sourceId) async {
    _requireOpen();
    if (_registry.ownerOfSource(sourceId) != null) return true;
    final candidates = _installed.values.where((record) {
      if (record.sourceIds.contains(sourceId)) return true;
      return record.plugin.sources.any((source) => source.sourceId == sourceId);
    }).toList(growable: false);
    if (candidates.length != 1) {
      final hasUndiscoveredOwner = _installed.values.any(
        (record) => record.sourceIds.isEmpty && record.plugin.requiresRuntimeDiscovery,
      );
      if (candidates.isEmpty && !hasUndiscoveredOwner) return false;
      // Old/runtime-discovered manifests may not yet contain a stable source
      // owner. Preserve compatibility by falling back to the complete
      // activation pass only while such an owner can actually be undiscovered
      // (or if persisted ownership is already ambiguous).
      await _ensureAllActivated();
      return _registry.ownerOfSource(sourceId) != null;
    }
    await _activateRecord(candidates.single);
    return _registry.ownerOfSource(sourceId) != null;
  }

  /// Emits whenever startup or an explicit lifecycle operation changes the
  /// active source projection. Consumers can publish each source as soon as
  /// its own runtime is ready instead of waiting behind a sibling plugin.
  Stream<void> get sourceChanges => _sourceChanges.stream;

  Future<void> _prepare() async {
    await _root.create(recursive: true);
    await _readManifest();
  }

  Future<void> _initializeInBackground() async {
    final activation = _activateInstalled();
    if (!discoverDeviceMihonExtensions) {
      await activation;
      return;
    }
    final discovery = () async {
      try {
        await refreshDeviceMihonExtensions();
      } on Object catch (error) {
        _deviceMihonExtensions = const <InstalledMihonExtension>[];
        _deviceMihonDiscoveryError = error;
      }
    }();
    await Future.wait<void>(<Future<void>>[discovery, activation]);
  }

  List<InstalledExternalPlugin> get installed =>
      List<InstalledExternalPlugin>.unmodifiable(_installed.values);

  List<InstalledMihonExtension> get deviceMihonExtensions =>
      List<InstalledMihonExtension>.unmodifiable(_deviceMihonExtensions);

  Object? get deviceMihonDiscoveryError => _deviceMihonDiscoveryError;

  InstalledMihonScan get deviceMihonScan => _deviceMihonScan;

  List<InstalledMihonDiscoveryFailure> get deviceMihonDiscoveryFailures =>
      _deviceMihonScan.failures;

  List<BrowsableComicSource> get activeSources => _registry.activeSources;

  String? ownerOfSource(String sourceId) => _registry.ownerOfSource(sourceId);

  Map<String, Object> get activationFailures =>
      Map<String, Object>.unmodifiable(_activationFailures);

  /// Whether the last activation failure can be retried without reinstalling
  /// or changing the trusted plugin record.
  bool canRetryActivation(String pluginId) {
    final failure = _activationFailures[pluginId];
    return failure != null && _isRetryableActivationFailure(failure);
  }

  Map<String, Object> get manifestRestoreFailures =>
      Map<String, Object>.unmodifiable(_manifestRestoreFailures);

  /// Mihon-only runtime refresh used by the existing browser/Cloudflare
  /// handoff. Runtime settings and Venera login are explicitly in-place and
  /// must never call this lifecycle operation.
  Future<void> restartMihonSourceForBrowserHandoff(String sourceId) async {
    _requireOpen();
    if (!sourceId.startsWith('mihon:')) {
      throw ArgumentError.value(
        sourceId,
        'sourceId',
        'browser runtime restart is Mihon-only',
      );
    }
    final pluginId = _registry.ownerOfSource(sourceId);
    if (pluginId == null) {
      throw StateError('external source is not active: $sourceId');
    }
    await _runDurableMutation(
      pluginId,
      () => _restartMihonSourceForBrowserHandoff(
        pluginId: pluginId,
        sourceId: sourceId,
      ),
    );
  }

  Future<void> _restartMihonSourceForBrowserHandoff({
    required String pluginId,
    required String sourceId,
  }) async {
    if (_registry.ownerOfSource(sourceId) != pluginId) {
      throw StateError('external source is no longer active: $sourceId');
    }
    final record = _installed[pluginId];
    if (record == null) {
      throw StateError('external source owner is not installed: $pluginId');
    }
    if (record.plugin.format != ExternalComicPluginFormat.mihonExtension) {
      throw StateError('source owner is not a Mihon extension: $pluginId');
    }
    try {
      await _registry.replace(record.plugin);
      _activationFailures.remove(pluginId);
      _notifySourceChange();
    } on Object catch (error) {
      _activationFailures[pluginId] = error;
      rethrow;
    }
  }

  Future<void> refreshDeviceMihonExtensions({
    Iterable<String> knownPackageNames = const <String>[],
  }) async {
    _requireOpen();
    if (!Platform.isAndroid) {
      _deviceMihonExtensions = const <InstalledMihonExtension>[];
      _deviceMihonScan = const InstalledMihonScan.empty();
      _deviceMihonDiscoveryError = null;
      return;
    }
    final known = <String>{
      for (final record in _installed.values)
        if (record.packageName != null) record.packageName!,
      ...knownPackageNames,
    };
    try {
      final scan = await _androidMihonMetadata.scanInstalled(
        knownPackageNames: known,
      );
      _deviceMihonScan = scan;
      _deviceMihonExtensions = scan.extensions;
      _deviceMihonDiscoveryError = scan.enumerationErrors.isEmpty
          ? null
          : StateError(scan.enumerationErrors.join('\n'));
    } on Object catch (error) {
      _deviceMihonDiscoveryError = error;
      rethrow;
    }
  }

  Future<List<ExternalComicPluginCatalogEntry>> loadRepository({
    required ExternalComicPluginFormat format,
    required Uri index,
  }) async {
    _requireOpen();
    _requireHttps(index);
    final effectiveIndex = switch (format) {
      ExternalComicPluginFormat.mihonExtension =>
        await _resolveMihonRepositoryIndex(index),
      ExternalComicPluginFormat.veneraJavaScript => index,
    };
    final document = utf8.decode(
      await _downloadBytes(effectiveIndex, maxBytes: 16 * 1024 * 1024),
    );
    final base = effectiveIndex.resolve('.');
    return switch (format) {
      ExternalComicPluginFormat.mihonExtension =>
        parseMihonExtensionIndex(document, repositoryBase: base),
      ExternalComicPluginFormat.veneraJavaScript =>
        parseVeneraSourceIndex(document, repositoryBase: base),
    };
  }

  /// Mihon 0.20.1+ advertises the compact protobuf index, while extension
  /// repositories continue to publish the equivalent full JSON index used by
  /// zic's transport-neutral catalog parser. Accept both the advertised
  /// `index.pb` URL and the repository descriptor without adding protobuf to
  /// the executable-plugin boundary.
  Future<Uri> _resolveMihonRepositoryIndex(Uri requested) async {
    if (_hasFilename(requested, 'repo.json')) {
      final descriptor = jsonDecode(
        utf8.decode(
          await _downloadBytes(requested, maxBytes: 256 * 1024),
        ),
      );
      if (descriptor is! Map<Object?, Object?>) {
        throw const FormatException('Mihon repository descriptor is invalid');
      }
      final advertised = descriptor['index_v2'];
      if (advertised is! String || advertised.trim().isEmpty) {
        throw const FormatException(
          'Mihon repository descriptor is missing index_v2',
        );
      }
      final resolved = requested.resolve(advertised.trim());
      _requireHttps(resolved);
      return _mihonJsonCompanion(resolved);
    }
    return _mihonJsonCompanion(requested);
  }

  Future<ExternalPluginInstallPreview> inspect({
    required ExternalComicPluginCatalogEntry plugin,
    required Uri repository,
  }) async {
    _requireOpen();
    _requireHttps(repository);
    final previewGeneration = _beginPreviewGeneration(plugin.pluginId);
    final previousPending = _pendingPayloads.remove(plugin.pluginId);
    if (previousPending != null) {
      await _deleteBestEffort(File(previousPending.path));
    }
    final suffix = plugin.format == ExternalComicPluginFormat.mihonExtension
        ? '.apk'
        : '.js';
    final safeId = base64Url
        .encode(utf8.encode(plugin.pluginId))
        .replaceAll('=', '');
    final revision = DateTime.now().toUtc().microsecondsSinceEpoch;
    final payloadName = '$safeId-$revision$suffix';
    final partial = File('${_root.path}/$payloadName.part');
    final payload = File('${_root.path}/$payloadName');
    try {
      await _downloadToFile(
        plugin.entrypoint,
        partial,
        maxBytes: plugin.format == ExternalComicPluginFormat.mihonExtension
            ? 128 * 1024 * 1024
            : 4 * 1024 * 1024,
      );
      await partial.rename(payload.path);
      _requireOpen();
      _requireCurrentPreviewGeneration(
        plugin.pluginId,
        previewGeneration,
      );
    } on Object {
      _releasePreviewGeneration(plugin.pluginId, previewGeneration);
      await _deleteBestEffort(partial);
      await _deleteBestEffort(payload);
      rethrow;
    }
    final pending = _PendingPluginPayload(
      payload.path,
      previewGeneration,
    );
    _pendingPayloads[plugin.pluginId] = pending;
    try {
      final inspection = await _inspector(plugin.format).inspect(plugin);
      _requireOpen();
      _requireCurrentPreviewGeneration(
        plugin.pluginId,
        previewGeneration,
      );
      if (!identical(_pendingPayloads[plugin.pluginId], pending)) {
        throw StateError(
          'external plugin preview was superseded: ${plugin.pluginId}',
        );
      }
      return ExternalPluginInstallPreview._claimed(
        pending.claim,
        plugin: plugin,
        inspection: inspection,
        repository: repository,
      );
    } on Object {
      if (identical(_pendingPayloads[plugin.pluginId], pending)) {
        _pendingPayloads.remove(plugin.pluginId);
      }
      _releasePreviewGeneration(plugin.pluginId, previewGeneration);
      await _deleteBestEffort(payload);
      rethrow;
    }
  }

  Future<ExternalPluginInstallPreview> inspectInstalledMihon(
    InstalledMihonExtension extension,
  ) async {
    _requireOpen();
    final pluginId = 'mihon:${extension.packageName}';
    final previewGeneration = _beginPreviewGeneration(pluginId);
    final previousPending = _pendingPayloads.remove(pluginId);
    if (previousPending != null) {
      await _deleteBestEffort(File(previousPending.path));
    }
    final safeId = base64Url
        .encode(utf8.encode(pluginId))
        .replaceAll('=', '');
    final revision = DateTime.now().toUtc().microsecondsSinceEpoch;
    final partial = File('${_root.path}/$safeId-$revision.apk.part');
    final payload = File('${_root.path}/$safeId-$revision.apk');
    try {
      await _androidMihonMetadata.copyInstalled(
        packageName: extension.packageName,
        destinationPath: partial.path,
      );
      await partial.rename(payload.path);
      _requireOpen();
      _requireCurrentPreviewGeneration(pluginId, previewGeneration);
    } on Object {
      _releasePreviewGeneration(pluginId, previewGeneration);
      await _deleteBestEffort(partial);
      await _deleteBestEffort(payload);
      rethrow;
    }
    final pending = _PendingPluginPayload(
      payload.path,
      previewGeneration,
    );
    _pendingPayloads[pluginId] = pending;
    final entrypoint = Uri.https(
      'installed.mihon.invalid',
      '/${Uri.encodeComponent(extension.packageName)}.apk',
    );
    final plugin = ExternalComicPluginCatalogEntry(
      format: ExternalComicPluginFormat.mihonExtension,
      pluginId: pluginId,
      name: extension.displayName,
      version: extension.versionName,
      versionCode: extension.versionCode,
      entrypoint: entrypoint,
      sources: const <ExternalComicPluginSource>[],
      description: '设备上已安装的 Mihon 扩展',
      adult: true,
    );
    try {
      final inspection = await _mihonInspector.inspect(plugin);
      _requireOpen();
      _requireCurrentPreviewGeneration(pluginId, previewGeneration);
      if (!identical(_pendingPayloads[pluginId], pending)) {
        throw StateError('external plugin preview was superseded: $pluginId');
      }
      return ExternalPluginInstallPreview._claimed(
        pending.claim,
        plugin: plugin,
        inspection: inspection,
        repository: Uri.https('installed.mihon.invalid', '/'),
      );
    } on Object {
      if (identical(_pendingPayloads[pluginId], pending)) {
        _pendingPayloads.remove(pluginId);
      }
      _releasePreviewGeneration(pluginId, previewGeneration);
      await _deleteBestEffort(payload);
      rethrow;
    }
  }

  Future<void> discardPreview(ExternalPluginInstallPreview preview) async {
    _requireOpen();
    final pending = _pendingPayloads[preview.plugin.pluginId];
    if (pending == null ||
        !identical(pending.claim, preview._claim) ||
        pending.path != preview.inspection.payloadPath) {
      return;
    }
    _pendingPayloads.remove(preview.plugin.pluginId);
    _releasePreviewGeneration(preview.plugin.pluginId, preview._claim);
    await _deleteBestEffort(File(pending.path));
  }

  Future<List<BrowsableComicSource>> approveAndActivate(
    ExternalPluginInstallPreview preview,
  ) =>
      _runDurableMutation(
        preview.plugin.pluginId,
        () => _approveAndActivate(preview),
      );

  Future<List<BrowsableComicSource>> _approveAndActivate(
    ExternalPluginInstallPreview preview,
  ) async {
    final pending = _pendingPayloads[preview.plugin.pluginId];
    if (pending == null ||
        !identical(pending.claim, preview._claim) ||
        pending.path != preview.inspection.payloadPath) {
      throw StateError(
        'external plugin preview was superseded: ${preview.plugin.pluginId}',
      );
    }
    _pendingPayloads.remove(preview.plugin.pluginId);
    _releasePreviewGeneration(preview.plugin.pluginId, preview._claim);
    final path = pending.path;
    var record = InstalledExternalPlugin(
      plugin: preview.plugin,
      payloadPath: path,
      payloadSha256: preview.inspection.payloadSha256,
      repositoryOrigin: _origin(preview.repository),
      packageName: preview.inspection.packageName,
      signerSha256: preview.inspection.signerSha256,
      versionCode: preview.inspection.versionCode,
      extensionLib: preview.inspection.extensionLib,
      entryClasses: preview.inspection.mihonEntryClasses,
      sourceKey: preview.inspection.sourceKey,
    );
    final pluginId = record.plugin.pluginId;
    final previous = _installed[pluginId];
    final replacingActive = _registry.isActive(pluginId);
    // Payload resolution for the candidate reads the installed record. Publish
    // the candidate record in memory, but keep the previous runtime session
    // authoritative until registry.replace validates the new payload/source set.
    _installed[pluginId] = record;
    var runtimeReplaced = false;
    try {
      final sources = replacingActive
          ? await _registry.replace(record.plugin)
          : await _registry.activate(record.plugin);
      runtimeReplaced = true;
      final activatedIds = <String>[
        for (final source in sources) source.sourceId,
      ];
      if (!_listEquals(record.sourceIds, activatedIds)) {
        record = _withDiscoveredSourceIds(record, activatedIds);
        _installed[pluginId] = record;
      }
      _activationFailures.remove(pluginId);
      _notifySourceChange();
      await _writeManifest();
      if (previous != null && previous.payloadPath != record.payloadPath) {
        await _deleteBestEffort(File(previous.payloadPath));
      }
      return sources;
    } on Object catch (error) {
      if (!runtimeReplaced) {
        final keepForRetry = previous == null &&
            _isRetryableActivationFailure(error);
        if (keepForRetry) {
          // A transient activation failure must not erase the user's newly
          // enabled plugin. Keep the immutable payload and manifest record so
          // the installed row can retry without another download/approval.
          _installed[pluginId] = record;
          _activationFailures[pluginId] = error;
          try {
            await _writeManifest();
          } on Object catch (persistError) {
            _activationFailures[pluginId] = persistError;
          }
          _notifySourceChange();
        } else {
          // Transactional registry replacement leaves the old active session
          // untouched when candidate activation/validation fails. Restore only
          // the controller's manifest view; there is no session to reactivate.
          if (previous == null) {
            _installed.remove(pluginId);
          } else {
            _installed[pluginId] = previous;
          }
          _activationFailures[pluginId] = error;
          _notifySourceChange();
        }
        if (!keepForRetry &&
            (previous == null || previous.payloadPath != record.payloadPath)) {
          await _deleteBestEffort(File(record.payloadPath));
        }
      } else {
        // Runtime activation succeeded but persisting the new manifest failed.
        // Keep the already validated runtime/payload authoritative in memory;
        // deleting it here would create an active-session/payload mismatch.
        _installed[pluginId] = record;
        _activationFailures[pluginId] = error;
        _notifySourceChange();
      }
      rethrow;
    }
  }

  /// Retries an installed plugin after a recoverable activation failure.
  ///
  /// A currently active session is replaced when the failure came from a
  /// runtime refresh or manifest write; an inactive record is activated from
  /// its already-owned payload. The trusted record is never removed by this
  /// operation.
  Future<List<BrowsableComicSource>> retryActivation(String pluginId) =>
      _runDurableMutation(pluginId, () => _retryActivation(pluginId));

  Future<List<BrowsableComicSource>> _retryActivation(String pluginId) async {
    var record = _installed[pluginId];
    if (record == null) {
      throw StateError('external plugin is not installed: $pluginId');
    }
    final failure = _activationFailures[pluginId];
    if (failure != null && !_isRetryableActivationFailure(failure)) {
      throw StateError('external plugin activation failure is not retryable');
    }
    try {
      final sources = _registry.isActive(pluginId)
          ? await _registry.replace(record.plugin)
          : await _registry.activate(record.plugin);
      final activatedIds = <String>[
        for (final source in sources) source.sourceId,
      ];
      if (!_listEquals(record.sourceIds, activatedIds)) {
        record = _withDiscoveredSourceIds(record, activatedIds);
        _installed[pluginId] = record;
      }
      _activationFailures.remove(pluginId);
      await _writeManifest();
      _notifySourceChange();
      return sources;
    } on Object catch (error) {
      _activationFailures[pluginId] = error;
      _notifySourceChange();
      rethrow;
    }
  }

  Future<void> remove(String pluginId) =>
      _runDurableMutation(pluginId, () => _remove(pluginId));

  Future<void> _remove(String pluginId) async {
    await _registry.deactivate(pluginId);
    final removed = _installed.remove(pluginId);
    _activationFailures.remove(pluginId);
    _notifySourceChange();
    await _writeManifest();
    if (removed != null) {
      await _deleteBestEffort(File(removed.payloadPath));
    }
  }

  /// Checks each distinct trusted repository origin among installed plugins
  /// of [format] and returns newer catalog entries keyed by [pluginId].
  ///
  /// One unreachable repository never hides updates from the others; its
  /// plugins are simply absent from the result. Device-imported Mihon
  /// extensions without a real repository origin are skipped.
  Future<Map<String, ExternalComicPluginCatalogEntry>> checkUpdates({
    required ExternalComicPluginFormat format,
  }) async {
    _requireOpen();
    final origins = <String, List<InstalledExternalPlugin>>{};
    for (final record in _installed.values) {
      if (record.plugin.format != format) continue;
      final origin = Uri.tryParse(record.repositoryOrigin);
      if (origin == null ||
          origin.host == 'installed.mihon.invalid' ||
          origin.host.isEmpty) {
        continue;
      }
      origins.putIfAbsent(record.repositoryOrigin, () => []).add(record);
    }
    final updates = <String, ExternalComicPluginCatalogEntry>{};
    for (final entry in origins.entries) {
      final index = Uri.tryParse(entry.key);
      if (index == null) continue;
      final List<ExternalComicPluginCatalogEntry> entries;
      try {
        entries = await loadRepository(format: format, index: index);
      } on Object {
        continue;
      }
      for (final record in entry.value) {
        ExternalComicPluginCatalogEntry? latest;
        for (final candidate in entries) {
          if (candidate.pluginId == record.plugin.pluginId) {
            latest = candidate;
            break;
          }
        }
        if (latest == null) continue;
        if (externalPluginCatalogEntryIsNewer(
          latest,
          installed: record.plugin,
        )) {
          updates[record.plugin.pluginId] = latest;
        }
      }
    }
    return updates;
  }

  /// Returns the trusted Venera payload source of an installed plugin.
  Future<String> readVeneraJavaScript(String pluginId) async {
    final record = _requireVeneraRecord(pluginId);
    try {
      return await File(record.payloadPath).readAsString();
    } on FileSystemException catch (error) {
      throw StateError('venera plugin payload is unreadable: $error');
    }
  }

  /// Persists a user-edited Venera payload and re-activates the plugin from
  /// it.
  ///
  /// Local edits are explicitly user-owned trust: the edited script is
  /// inspected again (source key/capabilities may change), pinned under a new
  /// digest, and only replaces the running session after that inspection and
  /// activation succeed. The previous payload stays authoritative on any
  /// failure.
  Future<List<BrowsableComicSource>> saveVeneraJavaScript(
    String pluginId,
    String source,
  ) =>
      _runDurableMutation(
        pluginId,
        () => _saveVeneraJavaScript(pluginId, source),
      );

  Future<List<BrowsableComicSource>> _saveVeneraJavaScript(
    String pluginId,
    String source,
  ) async {
    final record = _requireVeneraRecord(pluginId);
    if (source.trim().isEmpty) {
      throw ArgumentError.value(source, 'source', 'must not be empty');
    }
    final previewGeneration = _beginPreviewGeneration(pluginId);
    final previousPending = _pendingPayloads.remove(pluginId);
    if (previousPending != null) {
      await _deleteBestEffort(File(previousPending.path));
    }
    final safeId =
        base64Url.encode(utf8.encode(pluginId)).replaceAll('=', '');
    final revision = DateTime.now().toUtc().microsecondsSinceEpoch;
    final payload = File('${_root.path}/$safeId-$revision.js');
    final partial = File('${payload.path}.part');
    try {
      await partial.parent.create(recursive: true);
      await partial.writeAsString(source, flush: true);
      await partial.rename(payload.path);
      _requireOpen();
      _requireCurrentPreviewGeneration(pluginId, previewGeneration);
    } on Object {
      _releasePreviewGeneration(pluginId, previewGeneration);
      await _deleteBestEffort(partial);
      await _deleteBestEffort(payload);
      rethrow;
    }
    final pending = _PendingPluginPayload(
      payload.path,
      previewGeneration,
    );
    _pendingPayloads[pluginId] = pending;
    final ExternalPluginInstallPreview preview;
    try {
      final inspection = await _veneraInspector.inspect(record.plugin);
      _requireOpen();
      _requireCurrentPreviewGeneration(pluginId, previewGeneration);
      if (!identical(_pendingPayloads[pluginId], pending)) {
        throw StateError('external plugin preview was superseded: $pluginId');
      }
      preview = ExternalPluginInstallPreview._claimed(
        pending.claim,
        plugin: record.plugin,
        inspection: inspection,
        repository: Uri.parse(record.repositoryOrigin),
      );
    } on Object catch (error) {
      if (identical(_pendingPayloads[pluginId], pending)) {
        _pendingPayloads.remove(pluginId);
      }
      _releasePreviewGeneration(pluginId, previewGeneration);
      await _deleteBestEffort(payload);
      throw StateError('编辑后的脚本无效：$error');
    }
    return _approveAndActivate(preview);
  }

  InstalledExternalPlugin _requireVeneraRecord(String pluginId) {
    _requireOpen();
    final record = _installed[pluginId];
    if (record == null ||
        record.plugin.format != ExternalComicPluginFormat.veneraJavaScript) {
      throw StateError('venera plugin is not installed: $pluginId');
    }
    return record;
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    final mutationsDrained = _durableMutations.beginClose();
    for (final client in _activeRepositoryClients.toList(growable: false)) {
      client.close(force: true);
    }
    _activeRepositoryClients.clear();
    try {
      // Enter registry shutdown immediately. Waiting for durable controller
      // mutations first could deadlock work that is currently inside the
      // registry. Once shutdown is in flight, every mutation admitted before
      // this close boundary may finish its rollback/manifest commit path.
      await _registry.close();
    } finally {
      try {
        await mutationsDrained;
        await _manifestWriteTail;
        await _discardPendingPayloads();
      } finally {
        await _sourceChanges.close();
      }
    }
  }

  Future<void> _discardPendingPayloads() async {
    final pending = _pendingPayloads.values
        .map((payload) => payload.path)
        .toSet()
        .toList(growable: false);
    _pendingPayloads.clear();
    _previewGenerations.clear();
    for (final path in pending) {
      await _deleteBestEffort(File(path));
    }
  }

  ExternalPluginInspector _inspector(ExternalComicPluginFormat format) =>
      switch (format) {
        ExternalComicPluginFormat.mihonExtension => _mihonInspector,
        ExternalComicPluginFormat.veneraJavaScript => _veneraInspector,
      };

  InstalledExternalPlugin? _installedRecord(String pluginId) =>
      _installed[pluginId];

  Future<ExternalPluginPayloadFile> _acquirePinnedPayload(
    ExternalComicPluginCatalogEntry plugin,
  ) async {
    final path = _pendingPayloads[plugin.pluginId]?.path ??
        _installed[plugin.pluginId]?.payloadPath;
    if (path == null) {
      throw StateError('plugin payload is not pinned: ${plugin.pluginId}');
    }
    final file = File(path);
    final length = await file.length();
    return ExternalPluginPayloadFile(path: path, byteLength: length);
  }

  Future<ExternalPluginPayloadFile> _acquireInstalledPayload(
    InstalledExternalPlugin record,
  ) async {
    final file = File(record.payloadPath);
    final length = await file.length();
    return ExternalPluginPayloadFile(
      path: record.payloadPath,
      byteLength: length,
    );
  }

  Future<ExternalPluginInspection> _inspectInstalledRecord(
    ExternalComicPluginCatalogEntry plugin,
    InstalledExternalPlugin record,
  ) async {
    final cached = await _cachedPinnedInspection(record);
    if (cached != null) return cached;

    final payloads = CallbackExternalPluginPayloadLoader(
      (_) => _acquireInstalledPayload(record),
    );
    return switch (record.plugin.format) {
      ExternalComicPluginFormat.mihonExtension => MihonApkInspector(
          payloads: payloads,
          metadata: const AndroidMihonApkMetadataReader(),
        ).inspect(plugin),
      ExternalComicPluginFormat.veneraJavaScript => VeneraJavaScriptInspector(
          payloads: payloads,
        ).inspect(plugin),
    };
  }

  Future<ExternalPluginInspection?> _cachedPinnedInspection(
    InstalledExternalPlugin record,
  ) async {
    // The manifest already contains the approved immutable payload identity
    // and runtime metadata. The Android executor still verifies the exact
    // payload length and SHA-256 before class loading; this warm path only
    // avoids repeating Dart metadata parsing and hashing on every app start.
    switch (record.plugin.format) {
      case ExternalComicPluginFormat.mihonExtension:
        if (record.packageName == null ||
            record.signerSha256 == null ||
            record.versionCode == null ||
            record.extensionLib == null ||
            record.entryClasses.isEmpty ||
            record.entryClasses.any((value) => value.trim().isEmpty)) {
          return null;
        }
      case ExternalComicPluginFormat.veneraJavaScript:
        if (record.sourceKey == null || record.sourceKey!.trim().isEmpty) {
          return null;
        }
    }
    final payload = await _acquireInstalledPayload(record);
    return ExternalPluginInspection(
      format: record.plugin.format,
      payloadSha256: record.payloadSha256,
      requestedCapabilities: switch (record.plugin.format) {
        ExternalComicPluginFormat.mihonExtension =>
          _mihonInspector.requestedCapabilities,
        ExternalComicPluginFormat.veneraJavaScript =>
          _veneraInspector.requestedCapabilities,
      },
      payloadPath: payload.path,
      payloadByteLength: payload.byteLength,
      packageName: record.packageName,
      signerSha256: record.signerSha256,
      versionCode: record.versionCode,
      extensionLib: record.extensionLib,
      mihonEntryClasses: record.entryClasses,
      sourceKey: record.sourceKey,
    );
  }

  Future<void> _activateInstalled() async {
    final records = _installed.values.toList(growable: false);
    if (records.isEmpty) return;
    var next = 0;
    Future<void> activateNext() async {
      while (true) {
        if (_closed) return;
        final index = next++;
        if (index >= records.length) return;
        await _activateRecord(records[index]);
      }
    }
    final workerCount = records.length < 4 ? records.length : 4;
    await Future.wait<void>(
      List<Future<void>>.generate(workerCount, (_) => activateNext()),
    );
  }

  Future<void> _activateRecord(InstalledExternalPlugin record) =>
      _runDurableMutation(record.plugin.pluginId, () async {
        if (!identical(_installed[record.plugin.pluginId], record)) {
          return;
        }
        try {
          final sources = await _registry.activate(record.plugin);
          final activatedIds = <String>[
            for (final source in sources) source.sourceId,
          ];
          if (!_listEquals(record.sourceIds, activatedIds)) {
            _installed[record.plugin.pluginId] =
                _withDiscoveredSourceIds(record, activatedIds);
            try {
              await _writeManifest();
            } on Object {
              // The runtime session is already active; persisting the newly
              // discovered identities must not fail the activation itself.
              // The next successful user-facing manifest write records them.
            }
          }
          _activationFailures.remove(record.plugin.pluginId);
          _notifySourceChange();
        } on Object catch (error) {
          _activationFailures[record.plugin.pluginId] = error;
          _notifySourceChange();
        }
      });

  void _notifySourceChange() {
    if (!_closed && !_sourceChanges.isClosed) {
      _sourceChanges.add(null);
    }
  }

  Future<void> _readManifest() async {
    final candidates = <File>[
      _manifest,
      File('${_manifest.path}.part'),
      File('${_manifest.path}.bak'),
      File('${_manifest.path}.invalid'),
    ];
    Object? lastDocumentError;
    for (final candidate in candidates) {
      if (!await candidate.exists()) continue;
      _installed.clear();
      try {
        final recoveredPath = await _readManifestDocument(candidate);
        final recoveredDocument = candidate.path != _manifest.path;
        if (recoveredDocument || recoveredPath) {
          await _writeManifest(backupCurrent: !recoveredDocument);
        }
        return;
      } on Object catch (error) {
        lastDocumentError = error;
        _installed.clear();
        _manifestRestoreFailures['manifest:${candidate.path}'] = error;
      }
    }
    if (lastDocumentError != null) {
      _manifestRestoreFailures['manifest'] = lastDocumentError;
    }
  }

  Future<bool> _readManifestDocument(File manifest) async {
    final decoded = jsonDecode(await manifest.readAsString());
    if (decoded is! Map<Object?, Object?> || decoded['version'] != 1) {
      throw const FormatException('external plugin manifest version invalid');
    }
    final records = decoded['plugins'];
    if (records is! List<Object?>) {
      throw const FormatException('external plugin records invalid');
    }
    final canonicalRoot = await _root.resolveSymbolicLinks();
    var recoveredPath = false;
    for (var index = 0; index < records.length; index++) {
      final raw = records[index];
      try {
        final record = _recordFromJson(raw);
        final restored = await _restoreOwnedPayloadRecord(
          record,
          canonicalRoot,
        );
        if (restored == null) {
          _manifestRestoreFailures[record.plugin.pluginId] = StateError(
            'external plugin payload is missing from the owned plugin root',
          );
          continue;
        }
        recoveredPath = recoveredPath || restored.payloadPath != record.payloadPath;
        _installed[restored.plugin.pluginId] = restored;
      } on Object catch (error) {
        // One stale/corrupt record must never invalidate every imported
        // plugin. Keep all independently valid records and surface the bad
        // record for diagnostics.
        _manifestRestoreFailures['manifest-record-$index'] = error;
      }
    }
    if (records.isNotEmpty && _installed.isEmpty) {
      throw StateError('external plugin manifest has no recoverable records');
    }
    return recoveredPath;
  }

  Future<void> _writeManifest({bool backupCurrent = true}) {
    // Background recovery activates up to four plugins concurrently and may
    // persist newly discovered source identities; the atomic write/rename
    // sequence itself must stay serialized.
    final previous = _manifestWriteTail;
    final operation =
        previous.then((_) => _writeManifestNow(backupCurrent: backupCurrent));
    _manifestWriteTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  Future<void> _writeManifestNow({required bool backupCurrent}) async {
    await _root.create(recursive: true);
    final partial = File('${_manifest.path}.part');
    final backup = File('${_manifest.path}.bak');
    final document = jsonEncode(<String, Object?>{
      'version': 1,
      'plugins': _installed.values.map(_recordToJson).toList(),
    });
    await partial.writeAsString(document, flush: true);
    if (backupCurrent && await _manifest.exists()) {
      if (await backup.exists()) await backup.delete();
      await _manifest.rename(backup.path);
    } else if (await _manifest.exists()) {
      await _manifest.delete();
    }
    try {
      await partial.rename(_manifest.path);
    } on Object {
      if (!await _manifest.exists() && await backup.exists()) {
        await backup.copy(_manifest.path);
      }
      rethrow;
    }
  }

  Future<List<int>> _downloadBytes(Uri uri, {required int maxBytes}) async {
    final chunks = <int>[];
    await _download(
      uri,
      maxBytes: maxBytes,
      onChunk: chunks.addAll,
    );
    return chunks;
  }

  Future<void> _downloadToFile(
    Uri uri,
    File destination, {
    required int maxBytes,
  }) async {
    await destination.parent.create(recursive: true);
    final sink = destination.openWrite(mode: FileMode.writeOnly);
    Object? writeError;
    StackTrace? writeStackTrace;
    try {
      await _download(
        uri,
        maxBytes: maxBytes,
        onChunk: sink.add,
      );
    } on Object catch (error, stackTrace) {
      writeError = error;
      writeStackTrace = stackTrace;
    } finally {
      try {
        await sink.flush();
        await sink.close();
      } on Object catch (error, stackTrace) {
        writeError ??= error;
        writeStackTrace ??= stackTrace;
      }
    }
    if (writeError != null) {
      Error.throwWithStackTrace(writeError, writeStackTrace!);
    }
  }

  Future<void> _download(
    Uri uri, {
    required int maxBytes,
    required void Function(List<int> chunk) onChunk,
  }) async {
    _requireOpen();
    _requireHttps(uri);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 15);
    _activeRepositoryClients.add(client);
    try {
      var current = uri;
      for (var redirect = 0; redirect < 6; redirect++) {
        final request = await client.getUrl(current);
        final configuredUserAgent = userAgentProvider?.call().trim();
        request.headers
          ..set(HttpHeaders.acceptHeader, '*/*')
          ..set(
            HttpHeaders.userAgentHeader,
            configuredUserAgent != null && configuredUserAgent.isNotEmpty
                ? configuredUserAgent
                : 'zic/0.31.0 plugin-host',
          );
        request.followRedirects = false;
        final response = await request.close();
        if (response.isRedirect) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await response.drain<void>();
          if (location == null) {
            throw const HttpException('redirect location missing');
          }
          current = current.resolve(location);
          _requireHttps(current);
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          await response.drain<void>();
          throw HttpException(
            'plugin repository returned HTTP ${response.statusCode}',
            uri: current,
          );
        }
        final expected = response.contentLength;
        if (expected > maxBytes) {
          await response.drain<void>();
          throw const FormatException('plugin repository payload is too large');
        }
        var received = 0;
        await for (final chunk in response) {
          _requireOpen();
          received += chunk.length;
          if (received > maxBytes) {
            throw const FormatException('plugin repository payload is too large');
          }
          onChunk(chunk);
        }
        _requireOpen();
        return;
      }
      throw const HttpException('too many plugin repository redirects');
    } finally {
      _activeRepositoryClients.remove(client);
      client.close(force: true);
    }
  }

  Object _beginPreviewGeneration(String pluginId) {
    final generation = Object();
    _previewGenerations[pluginId] = generation;
    return generation;
  }

  void _requireCurrentPreviewGeneration(
    String pluginId,
    Object generation,
  ) {
    if (!identical(_previewGenerations[pluginId], generation)) {
      throw StateError('external plugin preview was superseded: $pluginId');
    }
  }

  void _releasePreviewGeneration(
    String pluginId,
    Object? generation,
  ) {
    if (generation != null &&
        identical(_previewGenerations[pluginId], generation)) {
      _previewGenerations.remove(pluginId);
    }
  }

  Future<T> _runDurableMutation<T>(
    String pluginId,
    Future<T> Function() action,
  ) {
    _requireOpen();
    return _durableMutations.run(pluginId, action);
  }

  void _requireOpen() {
    if (_closed) throw StateError('external plugin controller is closed');
  }
}

final class _PinnedExternalPluginHost implements ExternalComicPluginHost {
  const _PinnedExternalPluginHost({
    required this.format,
    required this.inspectRecord,
    required this.executor,
    required this.recordFor,
  });

  @override
  final ExternalComicPluginFormat format;
  final Future<ExternalPluginInspection> Function(
    ExternalComicPluginCatalogEntry plugin,
    InstalledExternalPlugin record,
  ) inspectRecord;
  final ExternalPluginExecutor executor;
  final InstalledExternalPlugin? Function(String pluginId) recordFor;

  @override
  Future<ExternalComicPluginSession> activate(
    ExternalComicPluginCatalogEntry plugin,
  ) async {
    final record = recordFor(plugin.pluginId);
    if (record == null || record.plugin.format != format) {
      throw ExternalPluginActivationException(
        pluginId: plugin.pluginId,
        denials: const <ExternalPluginDenial>{
          ExternalPluginDenial.payloadNotTrusted,
        },
      );
    }
    final inspection = await inspectRecord(plugin, record);
    if (!_matchesPin(record, inspection)) {
      throw ExternalPluginActivationException(
        pluginId: plugin.pluginId,
        denials: const <ExternalPluginDenial>{
          ExternalPluginDenial.payloadNotTrusted,
        },
      );
    }
    final policy = ExternalPluginTrustPolicy(
      trustedRepositoryOrigins: <String>{
        record.repositoryOrigin,
        _origin(plugin.entrypoint),
      },
      trustedPayloadSha256: <String>{record.payloadSha256},
      trustedMihonSignerSha256: <String>{
        if (record.signerSha256 != null) record.signerSha256!,
      },
      allowedMihonExtensionLibs: <String>{
        if (record.extensionLib != null) record.extensionLib!,
      },
      allowedMihonCapabilities: inspection.requestedCapabilities,
      allowedVeneraCapabilities: inspection.requestedCapabilities,
      minimumVersionCodes: <String, int>{
        if (record.versionCode != null) plugin.pluginId: record.versionCode!,
      },
      allowAdult: plugin.adult,
    );
    return PermissionedExternalComicPluginHost(
      inspector: _PinnedInspection(format, inspection),
      executor: executor,
      policy: policy,
      quarantineActivationFailures: false,
    ).activate(plugin);
  }
}

final class _PinnedInspection implements ExternalPluginInspector {
  const _PinnedInspection(this.format, this.value);

  @override
  final ExternalComicPluginFormat format;
  final ExternalPluginInspection value;

  @override
  Future<ExternalPluginInspection> inspect(
    ExternalComicPluginCatalogEntry plugin,
  ) async => value;
}

bool _matchesPin(
  InstalledExternalPlugin record,
  ExternalPluginInspection inspection,
) =>
    record.payloadPath == inspection.payloadPath &&
    record.payloadSha256 == inspection.payloadSha256 &&
    record.packageName == inspection.packageName &&
    record.signerSha256 == inspection.signerSha256 &&
    record.versionCode == inspection.versionCode &&
    record.extensionLib == inspection.extensionLib &&
    _listEquals(record.entryClasses, inspection.mihonEntryClasses) &&
    record.sourceKey == inspection.sourceKey;

bool _listEquals(List<String> left, List<String> right) =>
    left.length == right.length &&
    Iterable<int>.generate(left.length).every((index) => left[index] == right[index]);

bool _isRetryableActivationFailure(Object error) {
  if (error is ExternalPluginActivationException) {
    const terminalDenials = <ExternalPluginDenial>{
      ExternalPluginDenial.formatMismatch,
      ExternalPluginDenial.insecureEntrypoint,
      ExternalPluginDenial.untrustedRepository,
      ExternalPluginDenial.quarantined,
      ExternalPluginDenial.adultContentDenied,
      ExternalPluginDenial.payloadNotTrusted,
      ExternalPluginDenial.packageMismatch,
      ExternalPluginDenial.signerNotTrusted,
      ExternalPluginDenial.versionMismatch,
      ExternalPluginDenial.versionRollback,
      ExternalPluginDenial.unsupportedAbi,
      ExternalPluginDenial.capabilityDenied,
      ExternalPluginDenial.sourceIdentityMismatch,
      ExternalPluginDenial.inspectionFailed,
      ExternalPluginDenial.runtimeMetadataMissing,
    };
    return error.denials.every((denial) => !terminalDenials.contains(denial));
  }
  if (error is ExternalPluginRuntimeProcessException) {
    const terminalCodes = <String>{
      'limits-unsupported',
      'payload-too-large',
      'payload-changed',
      'payload-identity-mismatch',
      'source-identity-mismatch',
    };
    return !terminalCodes.contains(error.code);
  }
  if (error is FormatException || error is ArgumentError) {
    return false;
  }
  return true;
}

bool _hasFilename(Uri uri, String filename) =>
    uri.pathSegments.isNotEmpty && uri.pathSegments.last == filename;

Uri _mihonJsonCompanion(Uri uri) {
  if (!_hasFilename(uri, 'index.pb')) return uri;
  return uri.replace(
    pathSegments: <String>[
      ...uri.pathSegments.take(uri.pathSegments.length - 1),
      'index.json',
    ],
  );
}

void _requireHttps(Uri uri) {
  if (uri.scheme != 'https' || uri.host.isEmpty) {
    throw ArgumentError.value(uri, 'uri', 'must be an absolute HTTPS URI');
  }
}

/// Returns whether [candidate] should be offered to the user as an update
/// over [installed].
///
/// Version codes decide when both sides publish them; without codes, any
/// different version string counts so repositories that only bump the string
/// still surface a reminder.
bool externalPluginCatalogEntryIsNewer(
  ExternalComicPluginCatalogEntry candidate, {
  required ExternalComicPluginCatalogEntry installed,
}) {
  final candidateCode = candidate.versionCode;
  final installedCode = installed.versionCode;
  if (candidateCode != null && installedCode != null) {
    return candidateCode > installedCode;
  }
  return candidate.version != installed.version;
}

String _origin(Uri uri) {
  final port = uri.hasPort && uri.port != 443 ? ':${uri.port}' : '';
  return 'https://${uri.host}$port';
}

Map<String, Object?> _recordToJson(InstalledExternalPlugin record) =>
    <String, Object?>{
      'plugin': _pluginToJson(record.plugin),
      'payloadPath': record.payloadPath,
      'payloadSha256': record.payloadSha256,
      'repositoryOrigin': record.repositoryOrigin,
      'packageName': record.packageName,
      'signerSha256': record.signerSha256,
      'versionCode': record.versionCode,
      'extensionLib': record.extensionLib,
      'entryClasses': record.entryClasses,
      'sourceKey': record.sourceKey,
      'sourceIds': record.sourceIds,
    };

InstalledExternalPlugin _recordFromJson(Object? raw) {
  final json = _map(raw);
  return InstalledExternalPlugin(
    plugin: _pluginFromJson(json['plugin']),
    payloadPath: _string(json, 'payloadPath'),
    payloadSha256: _string(json, 'payloadSha256'),
    repositoryOrigin: _string(json, 'repositoryOrigin'),
    packageName: _optionalString(json['packageName']),
    signerSha256: _optionalString(json['signerSha256']),
    versionCode: json['versionCode'] as int?,
    extensionLib: _optionalString(json['extensionLib']),
    entryClasses: _optionalStringList(json['entryClasses']),
    sourceKey: _optionalString(json['sourceKey']),
    sourceIds: _optionalStringList(json['sourceIds']),
  );
}

/// Returns [record] with the source identities observed at activation.
InstalledExternalPlugin _withDiscoveredSourceIds(
  InstalledExternalPlugin record,
  List<String> sourceIds,
) =>
    InstalledExternalPlugin(
      plugin: record.plugin,
      payloadPath: record.payloadPath,
      payloadSha256: record.payloadSha256,
      repositoryOrigin: record.repositoryOrigin,
      packageName: record.packageName,
      signerSha256: record.signerSha256,
      versionCode: record.versionCode,
      extensionLib: record.extensionLib,
      entryClasses: record.entryClasses,
      sourceKey: record.sourceKey,
      sourceIds: List<String>.unmodifiable(sourceIds),
    );

Map<String, Object?> _pluginToJson(ExternalComicPluginCatalogEntry plugin) =>
    <String, Object?>{
      'format': plugin.format.name,
      'pluginId': plugin.pluginId,
      'name': plugin.name,
      'version': plugin.version,
      'entrypoint': plugin.entrypoint.toString(),
      'description': plugin.description,
      'language': plugin.language,
      'minHostVersion': plugin.minHostVersion,
      'versionCode': plugin.versionCode,
      'adult': plugin.adult,
      'requiresRuntimeDiscovery': plugin.requiresRuntimeDiscovery,
      'sources': plugin.sources.map((source) => <String, Object?>{
        'sourceId': source.sourceId,
        'externalId': source.externalId,
        'name': source.name,
        'language': source.language,
        'baseUri': source.baseUri?.toString(),
      }).toList(),
    };

ExternalComicPluginCatalogEntry _pluginFromJson(Object? raw) {
  final json = _map(raw);
  final format = ExternalComicPluginFormat.values.byName(_string(json, 'format'));
  final rawSources = json['sources'];
  if (rawSources is! List<Object?>) {
    throw const FormatException('external plugin source records invalid');
  }
  final sources = rawSources.map((rawSource) {
    final source = _map(rawSource);
    final base = _optionalString(source['baseUri']);
    return ExternalComicPluginSource(
      sourceId: _string(source, 'sourceId'),
      externalId: _string(source, 'externalId'),
      name: _string(source, 'name'),
      language: _string(source, 'language'),
      baseUri: base == null ? null : Uri.parse(base),
    );
  });
  return ExternalComicPluginCatalogEntry(
    format: format,
    pluginId: _string(json, 'pluginId'),
    name: _string(json, 'name'),
    version: _string(json, 'version'),
    entrypoint: Uri.parse(_string(json, 'entrypoint')),
    sources: sources,
    description: _optionalString(json['description']),
    language: _optionalString(json['language']),
    minHostVersion: _optionalString(json['minHostVersion']),
    versionCode: json['versionCode'] as int?,
    adult: json['adult'] == true,
    requiresRuntimeDiscovery: json['requiresRuntimeDiscovery'] == true,
  );
}

Map<String, Object?> _map(Object? value) {
  if (value is! Map<Object?, Object?> ||
      value.keys.any((key) => key is! String)) {
    throw const FormatException('external plugin manifest object invalid');
  }
  return Map<String, Object?>.from(value);
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('external plugin manifest field $key invalid');
  }
  return value;
}

String? _optionalString(Object? value) => switch (value) {
      null => null,
      final String text when text.trim().isEmpty => null,
      final String text => text,
      _ => throw const FormatException('external plugin optional string invalid'),
    };

List<String> _stringList(Object? value) {
  if (value is! List<Object?> || value.any((item) => item is! String)) {
    throw const FormatException('external plugin string list invalid');
  }
  return List<String>.unmodifiable(value.cast<String>());
}

List<String> _optionalStringList(Object? value) {
  if (value == null) return const <String>[];
  return _stringList(value);
}

Future<InstalledExternalPlugin?> _restoreOwnedPayloadRecord(
  InstalledExternalPlugin record,
  String canonicalRoot,
) async {
  if (await _isOwnedPayloadFile(record, canonicalRoot)) return record;
  final segments = File(record.payloadPath).uri.pathSegments;
  if (segments.isEmpty) return null;
  final basename = segments.last;
  if (basename.isEmpty) return null;
  final relocatedPath = '${Directory(canonicalRoot).path}${Platform.pathSeparator}$basename';
  final relocated = InstalledExternalPlugin(
    plugin: record.plugin,
    payloadPath: relocatedPath,
    payloadSha256: record.payloadSha256,
    repositoryOrigin: record.repositoryOrigin,
    packageName: record.packageName,
    signerSha256: record.signerSha256,
    versionCode: record.versionCode,
    extensionLib: record.extensionLib,
    entryClasses: record.entryClasses,
    sourceKey: record.sourceKey,
    sourceIds: record.sourceIds,
  );
  return await _isOwnedPayloadFile(relocated, canonicalRoot) ? relocated : null;
}

Future<bool> _isOwnedPayloadFile(
  InstalledExternalPlugin record,
  String canonicalRoot,
) async {
  try {
    final path = record.payloadPath;
    final expectedSuffix = switch (record.plugin.format) {
      ExternalComicPluginFormat.mihonExtension => '.apk',
      ExternalComicPluginFormat.veneraJavaScript => '.js',
    };
    if (!path.endsWith(expectedSuffix)) return false;
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      return false;
    }
    final canonicalPayload = await File(path).resolveSymbolicLinks();
    final rootPrefix = canonicalRoot.endsWith(Platform.pathSeparator)
        ? canonicalRoot
        : '$canonicalRoot${Platform.pathSeparator}';
    return canonicalPayload.startsWith(rootPrefix);
  } on FileSystemException {
    return false;
  }
}

Future<void> _deleteBestEffort(File file) async {
  try {
    if (await file.exists()) {
      await file.delete();
    }
  } on FileSystemException {
    // Persistent payload cleanup is best effort; trust remains digest-pinned.
  }
}

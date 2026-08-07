import 'dart:convert';
import 'dart:io';

import 'package:plugin_host/plugin_host.dart';
import 'android_mihon_metadata_reader.dart';
import 'method_channel_runtime_backends.dart';

final class ExternalPluginInstallPreview {
  const ExternalPluginInstallPreview({
    required this.plugin,
    required this.inspection,
    required this.repository,
  });

  final ExternalComicPluginCatalogEntry plugin;
  final ExternalPluginInspection inspection;
  final Uri repository;
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
}

/// App-shell owner for external repository discovery, immutable payload files,
/// user-pinned trust and activated source sessions.
///
/// Reader, download and cache services only see the returned ordinary
/// [BrowsableComicSource] adapters. Executable payloads remain owned by
/// plugin_host and its dedicated Android process.
final class ExternalPluginController {
  ExternalPluginController._({required this.storageRoot});

  final String storageRoot;
  late final Directory _root = Directory('$storageRoot/external_plugins');
  late final File _manifest = File('${_root.path}/installed.json');
  final Map<String, InstalledExternalPlugin> _installed =
      <String, InstalledExternalPlugin>{};
  final Map<String, String> _pendingPayloads = <String, String>{};
  final Map<String, Object> _activationFailures = <String, Object>{};
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
      inspector: _mihonInspector,
      executor: MihonIsolatedExecutor(
        backend: AndroidMihonIsolatedRuntimeBackend(),
      ),
      recordFor: _installedRecord,
    ),
    _PinnedExternalPluginHost(
      format: ExternalComicPluginFormat.veneraJavaScript,
      inspector: _veneraInspector,
      executor: VeneraSandboxExecutor(
        backend: AndroidVeneraSandboxRuntimeBackend(),
      ),
      recordFor: _installedRecord,
    ),
  ]);
  late final Future<void> _ready;
  bool _closed = false;

  static Future<ExternalPluginController> open(String storageRoot) async {
    final controller = await openDeferred(storageRoot);
    await controller.ready;
    return controller;
  }

  /// Opens the controller's durable manifest without activating installed
  /// runtimes. Activation continues in [ready] so optional plugin work cannot
  /// delay the first Home projection.
  static Future<ExternalPluginController> openDeferred(
    String storageRoot,
  ) async {
    final controller = ExternalPluginController._(storageRoot: storageRoot);
    await controller._prepare();
    controller._ready = controller._initializeInBackground();
    return controller;
  }

  /// Completes after device extension discovery and installed plugin
  /// activation have finished. Individual activation failures are retained in
  /// [activationFailures], matching the eager-open behavior.
  Future<void> get ready => _ready;

  Future<void> _prepare() async {
    await _root.create(recursive: true);
    await _readManifest();
  }

  Future<void> _initializeInBackground() async {
    try {
      await refreshDeviceMihonExtensions();
    } on Object catch (error) {
      _deviceMihonExtensions = const <InstalledMihonExtension>[];
      _deviceMihonDiscoveryError = error;
    }
    await _activateInstalled();
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

  Future<void> restartSource(String sourceId) async {
    _requireOpen();
    final pluginId = _registry.ownerOfSource(sourceId);
    if (pluginId == null) {
      throw StateError('external source is not active: $sourceId');
    }
    final record = _installed[pluginId];
    if (record == null) {
      throw StateError('external source owner is not installed: $pluginId');
    }
    await _registry.deactivate(pluginId);
    try {
      await _registry.activate(record.plugin);
      _activationFailures.remove(pluginId);
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
    final previousPending = _pendingPayloads.remove(plugin.pluginId);
    if (previousPending != null) {
      await _deleteBestEffort(File(previousPending));
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
    } on Object {
      await _deleteBestEffort(partial);
      rethrow;
    }
    _pendingPayloads[plugin.pluginId] = payload.path;
    try {
      final inspection = await _inspector(plugin.format).inspect(plugin);
      return ExternalPluginInstallPreview(
        plugin: plugin,
        inspection: inspection,
        repository: repository,
      );
    } on Object {
      _pendingPayloads.remove(plugin.pluginId);
      await _deleteBestEffort(payload);
      rethrow;
    }
  }

  Future<ExternalPluginInstallPreview> inspectInstalledMihon(
    InstalledMihonExtension extension,
  ) async {
    _requireOpen();
    final pluginId = 'mihon:${extension.packageName}';
    final previousPending = _pendingPayloads.remove(pluginId);
    if (previousPending != null) {
      await _deleteBestEffort(File(previousPending));
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
    } on Object {
      await _deleteBestEffort(partial);
      rethrow;
    }
    _pendingPayloads[pluginId] = payload.path;
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
      return ExternalPluginInstallPreview(
        plugin: plugin,
        inspection: inspection,
        repository: Uri.https('installed.mihon.invalid', '/'),
      );
    } on Object {
      _pendingPayloads.remove(pluginId);
      await _deleteBestEffort(payload);
      rethrow;
    }
  }

  Future<void> discardPreview(ExternalPluginInstallPreview preview) async {
    _requireOpen();
    final pending = _pendingPayloads[preview.plugin.pluginId];
    if (pending == null || pending != preview.inspection.payloadPath) {
      return;
    }
    _pendingPayloads.remove(preview.plugin.pluginId);
    await _deleteBestEffort(File(pending));
  }

  Future<List<BrowsableComicSource>> approveAndActivate(
    ExternalPluginInstallPreview preview,
  ) async {
    _requireOpen();
    final path = _pendingPayloads.remove(preview.plugin.pluginId) ??
        preview.inspection.payloadPath;
    if (path == null || path.trim().isEmpty) {
      throw StateError('external plugin preview payload is unavailable');
    }
    final record = InstalledExternalPlugin(
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
    final previous = _installed[record.plugin.pluginId];
    if (_registry.isActive(record.plugin.pluginId)) {
      await _registry.deactivate(record.plugin.pluginId);
    }
    _installed[record.plugin.pluginId] = record;
    try {
      final sources = await _registry.activate(record.plugin);
      _activationFailures.remove(record.plugin.pluginId);
      await _writeManifest();
      if (previous != null && previous.payloadPath != record.payloadPath) {
        await _deleteBestEffort(File(previous.payloadPath));
      }
      return sources;
    } on Object {
      await _deleteBestEffort(File(record.payloadPath));
      if (previous == null) {
        _installed.remove(record.plugin.pluginId);
      } else {
        _installed[record.plugin.pluginId] = previous;
        try {
          await _registry.activate(previous.plugin);
        } on Object {
          // The original activation error remains authoritative.
        }
      }
      rethrow;
    }
  }

  Future<void> remove(String pluginId) async {
    _requireOpen();
    await _registry.deactivate(pluginId);
    final removed = _installed.remove(pluginId);
    _activationFailures.remove(pluginId);
    await _writeManifest();
    if (removed != null) {
      await _deleteBestEffort(File(removed.payloadPath));
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _ready;
    } on Object {
      // Closing still drains any registry work below; background startup
      // errors must not escape the application shutdown path.
    }
    await _registry.close();
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
    final path = _pendingPayloads[plugin.pluginId] ??
        _installed[plugin.pluginId]?.payloadPath;
    if (path == null) {
      throw StateError('plugin payload is not pinned: ${plugin.pluginId}');
    }
    final file = File(path);
    final length = await file.length();
    return ExternalPluginPayloadFile(path: path, byteLength: length);
  }

  Future<void> _activateInstalled() async {
    for (final record in _installed.values.toList(growable: false)) {
      try {
        await _registry.activate(record.plugin);
      } on Object catch (error) {
        _activationFailures[record.plugin.pluginId] = error;
      }
    }
  }

  Future<void> _readManifest() async {
    if (!await _manifest.exists()) return;
    try {
      final decoded = jsonDecode(await _manifest.readAsString());
      if (decoded is! Map<Object?, Object?> || decoded['version'] != 1) {
        throw const FormatException('external plugin manifest version invalid');
      }
      final records = decoded['plugins'];
      if (records is! List<Object?>) {
        throw const FormatException('external plugin records invalid');
      }
      final canonicalRoot = await _root.resolveSymbolicLinks();
      for (final raw in records) {
        final record = _recordFromJson(raw);
        if (await _isOwnedPayloadFile(record, canonicalRoot)) {
          _installed[record.plugin.pluginId] = record;
        }
      }
    } on Object {
      final invalid = File('${_manifest.path}.invalid');
      if (await invalid.exists()) await invalid.delete();
      await _manifest.rename(invalid.path);
      _installed.clear();
    }
  }

  Future<void> _writeManifest() async {
    await _root.create(recursive: true);
    final partial = File('${_manifest.path}.part');
    final document = jsonEncode(<String, Object?>{
      'version': 1,
      'plugins': _installed.values.map(_recordToJson).toList(),
    });
    await partial.writeAsString(document, flush: true);
    if (await _manifest.exists()) await _manifest.delete();
    await partial.rename(_manifest.path);
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
    _requireHttps(uri);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 15);
    try {
      var current = uri;
      for (var redirect = 0; redirect < 6; redirect++) {
        final request = await client.getUrl(current);
        request.headers
          ..set(HttpHeaders.acceptHeader, '*/*')
          ..set(HttpHeaders.userAgentHeader, 'zic/0.31.0 plugin-host');
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
          received += chunk.length;
          if (received > maxBytes) {
            throw const FormatException('plugin repository payload is too large');
          }
          onChunk(chunk);
        }
        return;
      }
      throw const HttpException('too many plugin repository redirects');
    } finally {
      client.close(force: true);
    }
  }

  void _requireOpen() {
    if (_closed) throw StateError('external plugin controller is closed');
  }
}

final class _PinnedExternalPluginHost implements ExternalComicPluginHost {
  const _PinnedExternalPluginHost({
    required this.format,
    required this.inspector,
    required this.executor,
    required this.recordFor,
  });

  @override
  final ExternalComicPluginFormat format;
  final ExternalPluginInspector inspector;
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
    final inspection = await inspector.inspect(plugin);
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
      inspector: _PinnedInspection(inspector.format, inspection),
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
    entryClasses: _stringList(json['entryClasses']),
    sourceKey: _optionalString(json['sourceKey']),
  );
}

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

import 'dart:convert';

import 'source_catalog.dart';

enum ExternalComicPluginFormat {
  mihonExtension,
  veneraJavaScript,
}

final class ExternalComicPluginSource {
  const ExternalComicPluginSource({
    required this.sourceId,
    required this.externalId,
    required this.name,
    required this.language,
    this.baseUri,
  });

  /// zic-namespaced source identity. Never substitute a display name here.
  final String sourceId;

  /// Source identity as declared by the external runtime.
  final String externalId;
  final String name;
  final String language;
  final Uri? baseUri;
}

/// Repository-level plugin metadata before executable code is trusted or run.
final class ExternalComicPluginCatalogEntry {
  ExternalComicPluginCatalogEntry({
    required this.format,
    required this.pluginId,
    required this.name,
    required this.version,
    required this.entrypoint,
    required Iterable<ExternalComicPluginSource> sources,
    this.description,
    this.language,
    this.minHostVersion,
    this.versionCode,
    this.adult = false,
    this.requiresRuntimeDiscovery = false,
  }) : sources = List<ExternalComicPluginSource>.unmodifiable(sources);

  final ExternalComicPluginFormat format;
  final String pluginId;
  final String name;
  final String version;
  final Uri entrypoint;
  final List<ExternalComicPluginSource> sources;
  final String? description;
  final String? language;
  final String? minHostVersion;
  final int? versionCode;
  final bool adult;

  /// True only when repository metadata omits a stable external source key.
  /// The host must then evaluate metadata in a sandbox before a
  /// [BrowsableComicSource] can be registered.
  final bool requiresRuntimeDiscovery;
}

/// One activated plugin runtime with explicit teardown ownership.
abstract interface class ExternalComicPluginSession {
  ExternalComicPluginCatalogEntry get plugin;

  List<BrowsableComicSource> get sources;

  Future<void> close();
}

/// Runtime boundary for external source ecosystems.
///
/// APK/Kotlin and JavaScript execution stay outside catalog. A host validates,
/// sandboxes and adapts the external API, then returns ordinary zic sources in
/// a session whose lifecycle is explicit.
abstract interface class ExternalComicPluginHost {
  ExternalComicPluginFormat get format;

  Future<ExternalComicPluginSession> activate(
    ExternalComicPluginCatalogEntry plugin,
  );
}

List<ExternalComicPluginCatalogEntry> parseMihonExtensionIndex(
  String document, {
  Uri? repositoryBase,
}) {
  final decoded = jsonDecode(document);
  if (decoded is! List<Object?>) {
    throw const FormatException('Mihon extension index must be a JSON list');
  }
  return List<ExternalComicPluginCatalogEntry>.unmodifiable(
    decoded.map(
      (value) => _parseMihonEntry(
        _object(value, 'Mihon extension entry'),
        repositoryBase: repositoryBase,
      ),
    ),
  );
}

List<ExternalComicPluginCatalogEntry> parseVeneraSourceIndex(
  String document, {
  Uri? repositoryBase,
}) {
  final decoded = jsonDecode(document);
  if (decoded is! List<Object?>) {
    throw const FormatException('Venera source index must be a JSON list');
  }
  return List<ExternalComicPluginCatalogEntry>.unmodifiable(
    decoded.map(
      (value) => _parseVeneraEntry(
        _object(value, 'Venera source entry'),
        repositoryBase: repositoryBase,
      ),
    ),
  );
}

ExternalComicPluginCatalogEntry _parseMihonEntry(
  Map<String, Object?> json, {
  required Uri? repositoryBase,
}) {
  final packageName = _string(json, 'pkg');
  final apk = _string(json, 'apk');
  final rawSources = json['sources'];
  if (rawSources is! List<Object?>) {
    throw const FormatException('Mihon extension sources must be a list');
  }
  final sources = rawSources.map((value) {
    final source = _object(value, 'Mihon source entry');
    final externalId = _idString(source['id'], 'Mihon source id');
    final baseUrl = _optionalString(source['baseUrl']);
    return ExternalComicPluginSource(
      sourceId: 'mihon:$externalId',
      externalId: externalId,
      name: _string(source, 'name'),
      language: _string(source, 'lang'),
      baseUri: baseUrl == null ? null : Uri.parse(baseUrl),
    );
  });
  return ExternalComicPluginCatalogEntry(
    format: ExternalComicPluginFormat.mihonExtension,
    pluginId: 'mihon:$packageName',
    name: _string(json, 'name'),
    version: _string(json, 'version'),
    versionCode: _optionalInt(json['code'], 'Mihon extension code'),
    entrypoint: _resolveEntrypoint(apk, repositoryBase),
    sources: sources,
    language: _optionalString(json['lang']),
    adult: _adultFlag(json['nsfw']),
  );
}

ExternalComicPluginCatalogEntry _parseVeneraEntry(
  Map<String, Object?> json, {
  required Uri? repositoryBase,
}) {
  final url = _optionalString(json['url']);
  final filename = _veneraFilename(json);
  if ((url == null) == (filename == null)) {
    throw const FormatException(
      'Venera source entry must provide exactly one of url or filename',
    );
  }
  final entrypoint = _resolveEntrypoint(url ?? filename!, repositoryBase);
  final name = _string(json, 'name');
  final externalKey = _optionalString(json['key']);
  final language = _optionalString(json['language']) ??
      _optionalString(json['lang']) ??
      'und';
  final sources = externalKey == null
      ? const <ExternalComicPluginSource>[]
      : <ExternalComicPluginSource>[
          ExternalComicPluginSource(
            sourceId: 'venera:$externalKey',
            externalId: externalKey,
            name: name,
            language: language,
          ),
        ];
  return ExternalComicPluginCatalogEntry(
    format: ExternalComicPluginFormat.veneraJavaScript,
    pluginId: externalKey == null
        ? 'venera:${entrypoint.toString()}'
        : 'venera:$externalKey',
    name: name,
    version: _string(json, 'version'),
    entrypoint: entrypoint,
    sources: sources,
    description: _optionalString(json['description']),
    language: language,
    requiresRuntimeDiscovery: externalKey == null,
  );
}

String? _veneraFilename(Map<String, Object?> json) {
  final documented = _optionalString(json['filename']);
  final repository = _optionalString(json['fileName']);
  if (documented != null && repository != null && documented != repository) {
    throw const FormatException(
      'Venera filename and fileName fields must not conflict',
    );
  }
  return documented ?? repository;
}

Uri _resolveEntrypoint(String value, Uri? repositoryBase) {
  final parsed = Uri.parse(value);
  final resolved = parsed.hasScheme
      ? parsed
      : repositoryBase?.resolveUri(parsed);
  if (resolved == null) {
    throw FormatException('relative plugin entrypoint requires repositoryBase');
  }
  if (resolved.scheme != 'https' && resolved.scheme != 'http') {
    throw FormatException('plugin entrypoint must use http or https');
  }
  return resolved;
}

Map<String, Object?> _object(Object? value, String label) {
  if (value is! Map<Object?, Object?>) {
    throw FormatException('$label must be an object');
  }
  return value.cast<String, Object?>();
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}

String? _optionalString(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw const FormatException('optional string field has invalid type');
  }
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

int? _optionalInt(Object? value, String label) {
  if (value == null) {
    return null;
  }
  if (value is int && value >= 0) {
    return value;
  }
  throw FormatException('$label must be a non-negative integer');
}

String _idString(Object? value, String label) {
  if (value is String && value.trim().isNotEmpty) {
    return value;
  }
  if (value is int) {
    return value.toString();
  }
  throw FormatException('$label must be a string or integer');
}

bool _adultFlag(Object? value) => switch (value) {
      true => true,
      int flag => flag != 0,
      String flag => flag == '1' || flag.toLowerCase() == 'true',
      _ => false,
    };

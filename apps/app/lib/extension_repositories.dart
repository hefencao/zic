import 'dart:convert';

import 'package:catalog/catalog.dart';

/// User-owned indexes, independent of installed executable payloads and trust.
final class ExtensionRepository {
  const ExtensionRepository({required this.format, required this.index,
    this.enabled = true, this.name = ''});
  final ExternalComicPluginFormat format;
  final Uri index;
  final bool enabled;
  final String name;

  String get identity => jsonEncode([format.name, index.toString()]);
  Map<String, Object?> get data => {
    'enabled': enabled,
    if (name.trim().isNotEmpty) 'name': name.trim(),
  };

  ExtensionRepository copyWith({Uri? index, bool? enabled, String? name}) =>
      ExtensionRepository(format: format, index: index ?? this.index,
        enabled: enabled ?? this.enabled, name: name ?? this.name);

  String? get hostedRepository {
    try {
      var parts = index.pathSegments.where((part) => part.isNotEmpty).toList();
      final host = index.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
      if (host == 'api.github.com' && parts.firstOrNull == 'repos') {
        parts = parts.skip(1).toList();
      } else if (host == 'cdn.jsdelivr.net' && parts.firstOrNull == 'gh') {
        parts = parts.skip(1).toList();
      } else if (!{'github.com', 'raw.githubusercontent.com', 'gitlab.com',
          'gitee.com', 'codeberg.org', 'bitbucket.org', 'gist.github.com',
          'gist.githubusercontent.com'}.contains(host)) {
        return null;
      }
      if (host == 'gitlab.com' && parts.contains('-')) {
        parts = parts.take(parts.indexOf('-')).toList();
        if (parts.length < 2) return null;
        return parts.join('/');
      }
      if (parts.length < 2) return null;
      final repository = host == 'cdn.jsdelivr.net' ? parts[1].split('@').first : parts[1];
      return '${parts[0]}/$repository';
    } on FormatException {
      return null;
    }
  }

  String get displayName => name.trim().isNotEmpty
      ? name.trim() : hostedRepository ?? index.host;

  static ExtensionRepository parse(String identity, Map<String, Object?>? data) {
    final parts = jsonDecode(identity);
    if (parts is! List || parts.length != 2 || parts.any((value) => value is! String) ||
        jsonEncode(parts) != identity) throw const FormatException('无效的扩展仓库标识');
    final formats = ExternalComicPluginFormat.values.where((format) => format.name == parts[0]);
    if (formats.length != 1) throw const FormatException('无效的扩展仓库类型');
    final format = formats.single;
    final uri = Uri.parse(parts[1] as String);
    if (uri.scheme != 'https' || !uri.hasAuthority || uri.host.isEmpty ||
        uri.userInfo.isNotEmpty || uri.fragment.isNotEmpty || uri.toString().length > 8192 ||
        (data != null && (data.keys.any((key) => key != 'enabled' && key != 'name') ||
          data['enabled'] is! bool))) {
      throw const FormatException('仓库必须是有效的 HTTPS 索引');
    }
    if (data != null && data.containsKey('name') &&
        (data['name'] is! String || (data['name'] as String).length > 120)) {
      throw const FormatException('仓库名称必须是 120 字以内的文字');
    }
    return ExtensionRepository(format: format, index: uri, enabled: data?['enabled'] == true,
      name: (data?['name'] as String? ?? '').trim());
  }
}

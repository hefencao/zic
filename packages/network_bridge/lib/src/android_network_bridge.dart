import 'package:flutter/services.dart';

final class NetworkBrowserSnapshot {
  NetworkBrowserSnapshot({
    required this.currentUrl,
    required this.title,
    required Map<String, String> cookies,
    required Map<String, String> localStorage,
    this.userAgent,
  })  : cookies = Map<String, String>.unmodifiable(cookies),
        localStorage = Map<String, String>.unmodifiable(localStorage);

  final Uri currentUrl;
  final String title;
  final Map<String, String> cookies;
  final Map<String, String> localStorage;
  final String? userAgent;
}

/// Android-owned browser and cookie capability shared by built-in and external
/// source adapters. It owns no plugin session, transport, artifact, or Reader
/// state.
final class AndroidNetworkBridge {
  const AndroidNetworkBridge({
    MethodChannel channel = const MethodChannel(_channelName),
  }) : _channel = channel;

  static const String _channelName = 'dev.zic/network_bridge';
  final MethodChannel _channel;

  Future<void> openBrowser(Uri url, {String? userAgent}) async {
    _requireHttpUrl(url);
    final normalizedUserAgent = userAgent?.trim();
    await _channel.invokeMethod<void>(
      'openBrowser',
      <String, Object?>{
        'url': url.toString(),
        if (normalizedUserAgent != null && normalizedUserAgent.isNotEmpty)
          'userAgent': normalizedUserAgent,
      },
    );
  }

  Future<NetworkBrowserSnapshot?> readBrowserSnapshot(Uri url) async {
    _requireHttpUrl(url);
    final value = await _channel.invokeMapMethod<String, Object?>(
      'readBrowserSnapshot',
      <String, Object?>{'url': url.toString()},
    );
    if (value == null) return null;
    final currentUrl = value['currentUrl'];
    final title = value['title'];
    if (currentUrl is! String || title is! String) {
      throw const FormatException('Android browser snapshot is invalid');
    }
    final parsedUrl = Uri.tryParse(currentUrl);
    if (parsedUrl == null ||
        (parsedUrl.scheme != 'https' && parsedUrl.scheme != 'http')) {
      throw const FormatException('Android browser snapshot URL is invalid');
    }
    return NetworkBrowserSnapshot(
      currentUrl: parsedUrl,
      title: title,
      cookies: _parseStringMap(value['cookies'], 'Android browser cookies'),
      localStorage: _parseStringMap(
        value['localStorage'],
        'Android browser local storage',
      ),
      userAgent: value['userAgent'] is String
          ? (value['userAgent'] as String).trim().isEmpty
              ? null
              : value['userAgent'] as String
          : null,
    );
  }
}

void _requireHttpUrl(Uri url) {
  if (url.scheme != 'https' && url.scheme != 'http') {
    throw ArgumentError.value(url, 'url', 'must use HTTP(S)');
  }
}

Map<String, String> _parseStringMap(Object? raw, String label) {
  if (raw == null) return const <String, String>{};
  if (raw is! Map) throw FormatException('$label is invalid');
  final result = <String, String>{};
  for (final entry in raw.entries) {
    if (entry.key is! String || entry.value is! String) {
      throw FormatException('$label is invalid');
    }
    result[entry.key as String] = entry.value as String;
  }
  return result;
}

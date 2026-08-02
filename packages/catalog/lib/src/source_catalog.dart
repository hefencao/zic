import 'dart:typed_data';

import 'comic_source.dart';

enum SourceContentRating { safe, suggestive, erotica, pornographic }

enum ComicSourceSettingKind { toggle, text, select, multiSelect, action }

final class ComicSourceSettingChoice {
  const ComicSourceSettingChoice({
    required this.value,
    required this.label,
  });

  final String value;
  final String label;
}

final class ComicSourceSetting {
  ComicSourceSetting({
    required this.key,
    required this.title,
    required this.kind,
    required this.value,
    this.summary,
    this.sensitive = false,
    Iterable<ComicSourceSettingChoice> choices =
        const <ComicSourceSettingChoice>[],
  }) : choices = List<ComicSourceSettingChoice>.unmodifiable(choices) {
    if (key.trim().isEmpty || title.trim().isEmpty) {
      throw ArgumentError('comic source setting identity must not be empty');
    }
  }

  final String key;
  final String title;
  final String? summary;
  final ComicSourceSettingKind kind;
  final Object value;
  final bool sensitive;
  final List<ComicSourceSettingChoice> choices;
}

abstract interface class ConfigurableComicSource {
  Future<List<ComicSourceSetting>> loadSettings();

  Future<void> updateSetting(String key, Object value);
}

final class ComicSourceAccount {
  ComicSourceAccount({
    required this.loggedIn,
    this.supportsCredentials = false,
    Iterable<String> cookieFields = const <String>[],
    this.loginWebsite,
    this.registerWebsite,
  }) : cookieFields = List<String>.unmodifiable(cookieFields);

  final bool loggedIn;
  final bool supportsCredentials;
  final List<String> cookieFields;
  final Uri? loginWebsite;
  final Uri? registerWebsite;

  bool get supportsLogin =>
      supportsCredentials || cookieFields.isNotEmpty || loginWebsite != null;
}

/// Optional source capability for resolving the human-facing comic page.
///
/// Opaque plugin identities stay inside the source adapter. Presentation only
/// receives a normal URI and never parses Mihon/Venera payloads.
abstract interface class ComicWebUriSource {
  Uri? resolveComicWebUri(String comicId);
}

/// Optional source-owned equivalence key for durable comic identities.
///
/// The returned value is only used to compare aliases emitted by the same
/// source. It is never passed back to [loadComic], persisted as a replacement
/// locator, or interpreted by Presentation. Plugin-specific opaque identities
/// therefore remain inside their adapter while App composition can collapse
/// duplicate projections of the same work.
abstract interface class CanonicalComicIdentitySource {
  String canonicalComicIdentity(String comicId);
}

/// Atomic browser configuration for one source-owned website request.
///
/// User-agent selection belongs to the source/network adapter because
/// Cloudflare clearance cookies can be bound to the browser user agent. The
/// App only forwards this immutable value to the shared network bridge.
final class ComicWebViewRequest {
  const ComicWebViewRequest({required this.url, this.userAgent});

  final Uri url;
  final String? userAgent;
}

abstract interface class ComicWebViewRequestSource {
  ComicWebViewRequest webViewRequest(Uri url);
}

abstract interface class AuthenticatableComicSource {
  Future<ComicSourceAccount> loadAccount();

  Future<void> loginWithCredentials(String account, String password);

  Future<void> loginWithCookies(Map<String, String> cookies);

  Future<void> confirmWebLogin({
    String? currentUrl,
    String? title,
    Map<String, String> cookies = const <String, String>{},
    Map<String, String> localStorage = const <String, String>{},
  });

  Future<void> logout();
}

final class ComicSourceDescriptor {
  const ComicSourceDescriptor({
    required this.sourceId,
    required this.name,
    required this.language,
    required this.website,
    this.supportsSearch = true,
    this.contentRatings = const <SourceContentRating>{
      SourceContentRating.safe,
      SourceContentRating.suggestive,
    },
  })  : assert(sourceId != ''),
        assert(name != ''),
        assert(language != ''),
        assert(contentRatings.length > 0);

  final String sourceId;
  final String name;
  final String language;
  final Uri website;
  final bool supportsSearch;
  final Set<SourceContentRating> contentRatings;
}

final class SourceComicSummary {
  const SourceComicSummary({
    required this.sourceId,
    required this.comicId,
    required this.title,
    required this.authors,
    this.tags = const <String>[],
    this.coverUri,
    this.description,
    this.contentRating = SourceContentRating.safe,
  });

  final String sourceId;
  final String comicId;
  final String title;
  final List<String> authors;
  final List<String> tags;
  final Uri? coverUri;
  final String? description;
  final SourceContentRating contentRating;
}

final class SourceBrowsePage {
  SourceBrowsePage({
    required Iterable<SourceComicSummary> items,
    required this.offset,
    required this.hasMore,
  })  : assert(offset >= 0),
        items = List<SourceComicSummary>.unmodifiable(items);

  final List<SourceComicSummary> items;
  final int offset;
  final bool hasMore;
}

/// Resolved source-owned media request. Source runtimes own URL/header
/// derivation; Reader/download sessions own transport, streaming and artifacts.
final class ComicResourceRequest {
  ComicResourceRequest({
    required this.uri,
    this.method = 'GET',
    Map<String, String> headers = const <String, String>{},
    Uint8List? body,
    this.requiresRuntimeTransform = false,
  })  : headers = Map<String, String>.unmodifiable(headers),
        body = body == null ? null : Uint8List.fromList(body) {
    if (!requiresRuntimeTransform &&
        uri.scheme != 'http' &&
        uri.scheme != 'https') {
      throw ArgumentError.value(uri, 'uri', 'direct requests must use HTTP(S)');
    }
    if (method.trim().isEmpty) {
      throw ArgumentError.value(method, 'method', 'must not be empty');
    }
  }

  final Uri uri;
  final String method;
  final Map<String, String> headers;
  final Uint8List? body;
  final bool requiresRuntimeTransform;
}

/// Optional capability used by pipeline transports to stream source-owned
/// resources without routing complete image bodies through a plugin RPC.
abstract interface class ResolvableComicResourceSource {
  Future<ComicResourceRequest> resolveResource(Uri uri);
}

/// Optional companion capability for source-defined failure recovery.
///
/// The initial request remains streamable by the host. Only after that request
/// fails does the source runtime execute its `onLoadFailed` callback and return
/// a replacement request plan. This preserves VibeVenera's streaming fast path
/// without forcing every source that exposes a retry hook to proxy the complete
/// image body through the plugin runtime.
abstract interface class RetryableComicResourceSource {
  Future<ComicResourceRequest?> retryResource(Uri uri);
}

abstract interface class BrowsableComicSource implements ComicSource {
  ComicSourceDescriptor get descriptor;

  Future<SourceBrowsePage> browse({
    String query = '',
    int offset = 0,
    int limit = 24,
  });

  Future<Uint8List> loadResource(Uri uri);
}

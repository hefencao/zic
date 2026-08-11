import 'dart:typed_data';

import 'package:domain/domain.dart';

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


/// One source-owned browse section.
///
/// Sections represent real categories exposed by a source runtime, such as
/// Mihon's popular/latest endpoints or Venera's explore/category targets.
/// Runtime ecosystem (native/Mihon/Venera) and search filters are deliberately
/// not represented as sections.
final class SourceBrowseSection {
  const SourceBrowseSection({
    required this.sectionId,
    required this.label,
  })  : assert(sectionId != ''),
        assert(label != '');

  final String sectionId;
  final String label;
}

/// Optional source-owned browse-section capability.
abstract interface class SectionedBrowsableComicSource {
  Future<List<SourceBrowseSection>> loadBrowseSections();

  Future<SourceBrowsePage> browseSection(
    String sectionId, {
    String query = '',
    int offset = 0,
    int limit = 24,
  });
}

/// One normalized source-owned search-filter node.
///
/// Mihon sources return a `FilterList` whose concrete subclasses define the
/// schema and default state. ZIC preserves that source-owned structure instead
/// of guessing filter semantics from labels or flattening everything into
/// toggle chips.
enum SourceSearchFilterKind {
  header,
  separator,
  select,
  text,
  checkBox,
  triState,
  group,
  sort,
}

final class SourceSearchFilterNode {
  const SourceSearchFilterNode({
    required this.filterId,
    required this.kind,
    this.label = '',
    this.options = const <String>[],
    this.value,
    this.children = const <SourceSearchFilterNode>[],
  }) : assert(filterId != '');

  /// Opaque structural path owned by the source adapter.
  final String filterId;
  final SourceSearchFilterKind kind;
  final String label;
  final List<String> options;

  /// Source-provided default/current state for leaf filters.
  ///
  /// Wire-compatible values are bool/int/String/null, or the Sort state map
  /// `{index: int, ascending: bool}`. Presentation only edits these typed
  /// values; it never interprets source-specific labels.
  final Object? value;
  final List<SourceSearchFilterNode> children;
}

/// User overrides relative to the source-provided FilterList defaults.
///
/// Empty state means "use the source-provided defaults". Whether the request
/// is a filter browse is a separate mode bit owned by the caller/cache key.
typedef SourceSearchFilterState = Map<String, Object?>;

/// Optional source-owned search-filter capability.
///
/// Capability is represented by the actual schema returned by
/// [loadSearchFilters]. An empty list means this source has no exposed search
/// filters; there is no separate boolean capability that can drift from the
/// source's `getFilterList()` result.
abstract interface class FilterableBrowsableComicSource {
  Future<List<SourceSearchFilterNode>> loadSearchFilters();

  Future<SourceBrowsePage> browseWithFilters({
    String? sectionId,
    String query = '',
    int offset = 0,
    int limit = 24,
    SourceSearchFilterState filterState = const <String, Object?>{},
  });
}

final class CachedSourceBrowseSnapshot {
  CachedSourceBrowseSnapshot({
    required this.page,
    required this.sectionId,
    required this.query,
    required this.offset,
    required this.limit,
    SourceSearchFilterState filterState = const <String, Object?>{},
    this.useFilters = false,
  }) : filterState = Map<String, Object?>.unmodifiable(filterState);

  final SourceBrowsePage page;
  final String? sectionId;
  final String query;
  final int offset;
  final int limit;
  final SourceSearchFilterState filterState;
  final bool useFilters;
}

/// Optional cache projection used by Presentation for stale-while-revalidate.
///
/// The cache owner remains the catalog/resource-cache layer. Presentation may
/// show [peekBrowsePage] immediately, then call [refreshBrowsePage] in the
/// background and update only when the source returns different data.
abstract interface class CachedSourceBrowseProjection {
  CachedSourceBrowseSnapshot? peekLatestBrowseProjection();

  SourceBrowsePage? peekBrowsePage({
    String? sectionId,
    String query = '',
    int offset = 0,
    int limit = 24,
    SourceSearchFilterState filterState = const <String, Object?>{},
    bool useFilters = false,
  });

  Future<SourceBrowsePage> refreshBrowsePage({
    String? sectionId,
    String query = '',
    int offset = 0,
    int limit = 24,
    SourceSearchFilterState filterState = const <String, Object?>{},
    bool useFilters = false,
  });
}

/// A source-owned successor/predecessor relation.
///
/// The source adapter returns its opaque [comicId] unchanged so Presentation
/// can offer a version without parsing plugin identities or guessing from a
/// title search. A source may expose this capability when it has a stronger
/// relation than ordinary catalog search (for example E-Hentai's `#gnd`).
final class SourceComicVersion {
  const SourceComicVersion({
    required this.sourceId,
    required this.comicId,
    required this.title,
    required this.generation,
    this.date,
    this.isPredecessor = false,
  });

  final String sourceId;
  final String comicId;
  final String title;
  final int generation;
  final String? date;
  final bool isPredecessor;
}

/// Optional source-owned version discovery capability.
abstract interface class ComicVersionSource {
  bool get supportsComicVersions;

  Future<List<SourceComicVersion>> findComicVersions(String comicId);
}

/// Optional source-owned preview thumbnails for a comic detail page.
///
/// The first page may be embedded in [ComicManifest.preview]. This capability
/// is used only when a source exposes a separate cursor/pagination API.
abstract interface class ComicPreviewSource {
  bool get supportsComicPreview;

  Future<ComicPreviewPage> loadComicPreview(
    String comicId, {
    String? nextToken,
  });
}

/// Optional source-owned comments for a comic detail page.
///
/// [subId] and [replyTo] remain source-owned secondary identities. The App
/// forwards them without interpreting their format.
abstract interface class ComicCommentSource {
  bool get supportsComicComments;

  Future<ComicCommentPage> loadComicComments(
    String comicId, {
    String? subId,
    required int page,
    String? replyTo,
  });
}

/// A source-confirmed predecessor/successor relation remembered by the
/// library so a later detail page can also offer the older version.
final class ComicVersionRelation {
  const ComicVersionRelation({
    required this.sourceId,
    required this.predecessorComicId,
    required this.successorComicId,
    this.predecessorTitle = '',
    this.discoveredAt,
  });

  final String sourceId;
  final String predecessorComicId;
  final String successorComicId;
  final String predecessorTitle;
  final DateTime? discoveredAt;
}

/// Optional durable storage for source-confirmed version relations.
abstract interface class ComicVersionRelationStore {
  Future<List<ComicVersionRelation>> listAllComicVersionRelations();

  Future<List<ComicVersionRelation>> listComicVersionPredecessors(
    String sourceId,
    String successorComicId,
  );

  Future<List<ComicVersionRelation>> listComicVersionSuccessors(
    String sourceId,
    String predecessorComicId,
  );

  Future<void> saveComicVersionRelation(ComicVersionRelation relation);
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
    Map<String, Object?> diagnostics = const <String, Object?>{},
  })  : headers = Map<String, String>.unmodifiable(headers),
        body = body == null ? null : Uint8List.fromList(body),
        diagnostics = Map<String, Object?>.unmodifiable(diagnostics) {
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

  /// Read-only source-plan timing metadata for diagnostics only. Transport,
  /// cache, retry and scheduling policy must not depend on these values.
  final Map<String, Object?> diagnostics;
}

/// Optional capability used by pipeline transports to stream source-owned
/// resources without routing complete image bodies through a plugin RPC.
abstract interface class ResolvableComicResourceSource {
  Future<ComicResourceRequest> resolveResource(Uri uri);
}

/// Optional controlled variant used by Reader/download transport. The source
/// observes scheduler cancellation/priority but does not own scheduling policy.
abstract interface class ControlledResolvableComicResourceSource {
  Future<ComicResourceRequest> resolveResourceControlled(
    Uri uri, {
    TaskControl? control,
  });
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

abstract interface class ControlledRetryableComicResourceSource {
  Future<ComicResourceRequest?> retryResourceControlled(
    Uri uri, {
    TaskControl? control,
  });
}

abstract interface class ControlledComicResourceSource {
  Future<Uint8List> loadResourceControlled(
    Uri uri, {
    TaskControl? control,
  });
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

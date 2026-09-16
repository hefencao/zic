import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:reader/reader.dart';
import 'package:reader_runtime/reader_runtime.dart';

import 'debug_trace_export_destination.dart';

enum ShelfSourceFilter { all, local, remote }

enum ShelfViewPreference { gallery, list }

enum CachedCarrierTrustMode {
  strictReload,
  reuseThenRefresh,
  trustCached,
}

const defaultNetworkUserAgent =
    'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/150.0.0.0 Mobile Safari/537.36';

const defaultCacheLimitMb = 512;
const minCacheLimitMb = 64;
const maxCacheLimitMb = 8192;
const defaultReaderPrefetchReadBudgetMiB = 50;
const minReaderPrefetchReadBudgetMiB = 1;
const maxReaderPrefetchReadBudgetMiB = 1024;

@immutable
final class ComicReaderSettings {
  const ComicReaderSettings({
    this.enabled = false,
    this.directionOverride,
    this.verticalStitchOverride,
    this.adaptiveEnabled = true,
    this.adaptiveProfile,
    this.verticalLongPressZoom,
    this.invertPageOrder,
  });

  static const Object _unset = Object();

  final bool enabled;
  final ReadingDirection? directionOverride;
  final bool? verticalStitchOverride;
  final bool adaptiveEnabled;
  final AdaptiveReaderProfile? adaptiveProfile;
  final bool? verticalLongPressZoom;
  final bool? invertPageOrder;

  ComicReaderSettings copyWith({
    bool? enabled,
    Object? directionOverride = _unset,
    Object? verticalStitchOverride = _unset,
    bool? adaptiveEnabled,
    Object? adaptiveProfile = _unset,
    Object? verticalLongPressZoom = _unset,
    Object? invertPageOrder = _unset,
  }) =>
      ComicReaderSettings(
        enabled: enabled ?? this.enabled,
        directionOverride: identical(directionOverride, _unset)
            ? this.directionOverride
            : directionOverride as ReadingDirection?,
        verticalStitchOverride: identical(verticalStitchOverride, _unset)
            ? this.verticalStitchOverride
            : verticalStitchOverride as bool?,
        adaptiveEnabled: adaptiveEnabled ?? this.adaptiveEnabled,
        adaptiveProfile: identical(adaptiveProfile, _unset)
            ? this.adaptiveProfile
            : adaptiveProfile as AdaptiveReaderProfile?,
        verticalLongPressZoom: identical(verticalLongPressZoom, _unset)
            ? this.verticalLongPressZoom
            : verticalLongPressZoom as bool?,
        invertPageOrder: identical(invertPageOrder, _unset)
            ? this.invertPageOrder
            : invertPageOrder as bool?,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ComicReaderSettings &&
          enabled == other.enabled &&
          directionOverride == other.directionOverride &&
          verticalStitchOverride == other.verticalStitchOverride &&
          adaptiveEnabled == other.adaptiveEnabled &&
          adaptiveProfile == other.adaptiveProfile &&
          verticalLongPressZoom == other.verticalLongPressZoom &&
          invertPageOrder == other.invertPageOrder;

  @override
  int get hashCode => Object.hash(
        enabled,
        directionOverride,
        verticalStitchOverride,
        adaptiveEnabled,
        adaptiveProfile,
        verticalLongPressZoom,
        invertPageOrder,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'enabled': enabled,
        if (directionOverride != null)
          'directionOverride': directionOverride!.name,
        if (verticalStitchOverride != null)
          'verticalStitchOverride': verticalStitchOverride,
        'adaptiveEnabled': adaptiveEnabled,
        if (adaptiveProfile != null)
          'adaptiveProfile': adaptiveProfile!.toJson(),
        if (verticalLongPressZoom != null)
          'verticalLongPressZoom': verticalLongPressZoom,
        if (invertPageOrder != null)
          'invertPageOrder': invertPageOrder,
      };

  factory ComicReaderSettings.fromJson(Map<String, Object?> json) =>
      ComicReaderSettings(
        enabled: _boolValue(json['enabled'], false),
        directionOverride: _nullableEnumByName(
          ReadingDirection.values,
          json['directionOverride'],
        ),
        verticalStitchOverride: json['verticalStitchOverride'] is bool
            ? json['verticalStitchOverride'] as bool
            : json['verticalStitch'] == true
                ? true
                : null,
        adaptiveEnabled: _boolValue(json['adaptiveEnabled'], true),
        verticalLongPressZoom: json['verticalLongPressZoom'] is bool
            ? json['verticalLongPressZoom'] as bool
            : null,
        invertPageOrder: json['invertPageOrder'] is bool
            ? json['invertPageOrder'] as bool
            : null,
        adaptiveProfile: json['adaptiveProfile'] is Map
            ? AdaptiveReaderProfile.fromJson(
                Map<String, Object?>.from(
                  json['adaptiveProfile']! as Map,
                ),
              )
            : null,
      );
}

String comicReaderSettingsIdentity(String sourceId, String comicId) =>
    '$sourceId\u0000$comicId';

String comicVersionNoticeIdentity(
  String sourceId,
  String predecessorComicId,
  String successorComicId,
) =>
    '$sourceId\u0000$predecessorComicId\u0000$successorComicId';

/// Application-level preferences that are safe for Presentation to observe.
///
/// This controller owns only small user choices. It does not own cache files,
/// downloads, Reader sessions, network transports, or plugin storage.
final class AppPreferencesController extends ChangeNotifier {
  AppPreferencesController();

  final ChangeNotifier _themeChanges = ChangeNotifier();
  ThemeMode _themeMode = ThemeMode.dark;
  bool _amoledDarkTheme = false;
  bool _debugTraceEnabled = true;
  ShelfSourceFilter _shelfSourceFilter = ShelfSourceFilter.all;
  LibrarySortMode _shelfSortMode = LibrarySortMode.recent;
  ShelfViewPreference _shelfView = ShelfViewPreference.gallery;
  ReaderMode _defaultReaderMode = ReaderMode.paged;
  bool _readerStartsImmersive = true;
  bool _adaptiveReaderEnabled = false;
  bool _defaultVerticalStitch = false;
  double _defaultZoomStageFirst = 1.5;
  double _defaultZoomStageSecond = 2.0;
  bool _longPressZoomEnabled = true;
  bool _longPressZoomRestoreOnRelease = true;
  ReaderLongPressMoveMode _longPressZoomMoveMode =
      ReaderLongPressMoveMode.drag;
  double _longPressZoomPanRatio = 1.0;
  bool _longPressZoomLimitToViewport = true;
  ReaderDoubleTapZoomOrigin _doubleTapZoomOrigin =
      ReaderDoubleTapZoomOrigin.center;
  bool _zoomDecodeBoostEnabled = true;
  int _detailsPreviewMaxItemsPerRow = 4;
  String _networkUserAgent = defaultNetworkUserAgent;
  String _debugTraceExportDirectory = defaultDebugTraceExportDirectory;
  String? _chapterDownloadDirectoryOverride;
  String? _chapterDownloadDirectoryPendingMoveFrom;
  int _cacheLimitMb = defaultCacheLimitMb;
  int _readerPrefetchReadBudgetMiB = defaultReaderPrefetchReadBudgetMiB;
  CachedCarrierTrustMode _cachedCarrierTrustMode =
      CachedCarrierTrustMode.strictReload;
  Map<String, bool> _pluginTrustConflictingHistoricalCarriers =
      <String, bool>{};
  Map<String, String> _sourceDownloadDirectories = <String, String>{};
  List<String> _sourceSearchHistory = <String>[];
  Set<String> _acknowledgedComicVersionNotices = <String>{};
  Map<String, ComicReaderSettings> _comicReaderSettings =
      <String, ComicReaderSettings>{};
  Future<void> Function(Map<String, Object?> values)? _write;
  Future<void> _writeTail = Future<void>.value();
  int _revision = 0;
  bool _disposed = false;
  bool _attached = false;

  /// Narrow invalidation surface for the application theme shell.
  ///
  /// Most preferences are consumed by leaf screens or already-filtered Home
  /// projections. Rebuilding MaterialApp for those changes also rebuilds the
  /// covered Home route while Reader is active. Comic-level adaptive Reader
  /// settings are a particularly hot example because they may be persisted as
  /// runtime page evidence arrives. Keep the broad ChangeNotifier contract for
  /// existing preference consumers, but let the app shell observe only values
  /// that actually affect ThemeData/themeMode.
  Listenable get themeChanges => _themeChanges;

  ThemeMode get themeMode => _themeMode;
  bool get amoledDarkTheme => _amoledDarkTheme;
  bool get isAttached => _attached;
  bool get debugTraceEnabled => _debugTraceEnabled;
  ShelfSourceFilter get shelfSourceFilter => _shelfSourceFilter;
  LibrarySortMode get shelfSortMode => _shelfSortMode;
  ShelfViewPreference get shelfView => _shelfView;
  ReaderMode get defaultReaderMode => _defaultReaderMode;
  bool get readerStartsImmersive => _readerStartsImmersive;
  bool get adaptiveReaderEnabled => _adaptiveReaderEnabled;
  bool get defaultVerticalStitch => _defaultVerticalStitch;
  double get defaultZoomStageFirst => _defaultZoomStageFirst;
  double get defaultZoomStageSecond => _defaultZoomStageSecond;
  ReaderDoubleTapZoomOrigin get doubleTapZoomOrigin => _doubleTapZoomOrigin;
  bool get longPressZoomEnabled => _longPressZoomEnabled;
  bool get longPressZoomRestoreOnRelease => _longPressZoomRestoreOnRelease;
  ReaderLongPressMoveMode get longPressZoomMoveMode => _longPressZoomMoveMode;
  double get longPressZoomPanRatio => _longPressZoomPanRatio;
  bool get longPressZoomLimitToViewport => _longPressZoomLimitToViewport;
  bool get zoomDecodeBoostEnabled => _zoomDecodeBoostEnabled;
  int get detailsPreviewMaxItemsPerRow => _detailsPreviewMaxItemsPerRow;
  String get networkUserAgent => _networkUserAgent;
  String get debugTraceExportDirectory => _debugTraceExportDirectory;

  /// Absolute chapter-download store directory chosen by the user, or `null`
  /// to keep using the default `<storage root>/offline_chapters` location.
  ///
  /// This is a small user choice only. The bytes and the download index stay
  /// owned by the durable download composition; changing the value never
  /// moves files by itself.
  String? get chapterDownloadDirectoryOverride =>
      _chapterDownloadDirectoryOverride;

  /// Source directory of a chapter-download store move that has not been
  /// confirmed complete yet. Startup finishes or discards it; it is not user
  /// facing.
  String? get chapterDownloadDirectoryPendingMoveFrom =>
      _chapterDownloadDirectoryPendingMoveFrom;
  int get cacheLimitMb => _cacheLimitMb;
  int get readerPrefetchReadBudgetMiB => _readerPrefetchReadBudgetMiB;
  CachedCarrierTrustMode get cachedCarrierTrustMode => _cachedCarrierTrustMode;

  bool trustConflictingHistoricalCarriersForPlugin(String pluginId) =>
      _pluginTrustConflictingHistoricalCarriers[pluginId.trim()] ?? false;

  /// Per-source physical download roots chosen by the user, keyed by the
  /// external source identity (`venera:<key>` / `mihon:<id>`).
  ///
  /// A missing key keeps the effective default download directory. This only
  /// steers where NEW artifacts are written; existing bytes stay readable at
  /// their recorded location.
  Map<String, String> get sourceDownloadDirectories =>
      Map<String, String>.unmodifiable(_sourceDownloadDirectories);

  String? sourceDownloadDirectoryFor(String sourceId) {
    final directory = _sourceDownloadDirectories[sourceId];
    if (directory == null || directory.trim().isEmpty) return null;
    return directory;
  }
  List<String> get sourceSearchHistory =>
      List<String>.unmodifiable(_sourceSearchHistory);
  Set<String> get acknowledgedComicVersionNotices =>
      Set<String>.unmodifiable(_acknowledgedComicVersionNotices);
  Map<String, ComicReaderSettings> get comicReaderSettings =>
      Map<String, ComicReaderSettings>.unmodifiable(_comicReaderSettings);

  ComicReaderSettings comicReaderSettingsFor(String sourceId, String comicId) =>
      _comicReaderSettings[comicReaderSettingsIdentity(sourceId, comicId)] ??
      const ComicReaderSettings();

  Future<void> attach({
    required Future<Map<String, Object?>?> Function() read,
    required Future<void> Function(Map<String, Object?> values) write,
  }) async {
    if (_disposed) return;
    final revisionAtStart = _revision;
    Map<String, Object?>? values;
    try {
      values = await read();
    } on Object {
      if (!_disposed) {
        _write = write;
        if (_revision != revisionAtStart) {
          await _queuePersist();
        }
        _attached = true;
        notifyListeners();
      }
      rethrow;
    }
    if (_disposed) return;
    _write = write;
    if (_revision != revisionAtStart) {
      await _queuePersist();
      _attached = true;
      notifyListeners();
      return;
    }
    // A brand-new install can use the in-memory defaults until the user
    // changes a preference. Persisting the complete default document here
    // makes first startup perform a synchronous flush/rename on the UI
    // isolate and provides no user-visible benefit.
    if (values == null) {
      _attached = true;
      notifyListeners();
      return;
    }
    final priorThemeMode = _themeMode;
    final priorAmoledDarkTheme = _amoledDarkTheme;
    _themeMode = _enumByName(
      ThemeMode.values,
      values['themeMode'],
      _themeMode,
    );
    _amoledDarkTheme = _boolValue(
      values['amoledDarkTheme'],
      _amoledDarkTheme,
    );
    _debugTraceEnabled =
        _boolValue(values['debugTraceEnabled'], _debugTraceEnabled);
    _shelfSourceFilter = _enumByName(
      ShelfSourceFilter.values,
      values['shelfSourceFilter'],
      _shelfSourceFilter,
    );
    _shelfSortMode = _enumByName(
      LibrarySortMode.values,
      values['shelfSortMode'],
      _shelfSortMode,
    );
    _shelfView = _enumByName(
      ShelfViewPreference.values,
      values['shelfView'],
      _shelfView,
    );
    _defaultReaderMode = _enumByName(
      ReaderMode.values,
      values['defaultReaderMode'],
      _defaultReaderMode,
    );
    _readerStartsImmersive =
        _boolValue(values['readerStartsImmersive'], _readerStartsImmersive);
    _adaptiveReaderEnabled =
        _boolValue(values['adaptiveReaderEnabled'], _adaptiveReaderEnabled);
    _defaultVerticalStitch = _boolValue(
      values['defaultVerticalStitch'],
      _defaultVerticalStitch,
    );
    _defaultZoomStageFirst =
        _doubleValue(values['defaultZoomStage1'], _defaultZoomStageFirst,
            min: 1.1, max: 8);
    _defaultZoomStageSecond =
        _doubleValue(values['defaultZoomStage2'], _defaultZoomStageSecond,
            min: 1.1, max: 8);
    if (_defaultZoomStageSecond < _defaultZoomStageFirst) {
      _defaultZoomStageSecond = _defaultZoomStageFirst;
    }
    _longPressZoomEnabled =
        _boolValue(values['longPressZoomEnabled'], _longPressZoomEnabled);
    _longPressZoomRestoreOnRelease = _boolValue(
      values['longPressZoomRestoreOnRelease'],
      _longPressZoomRestoreOnRelease,
    );
    _longPressZoomMoveMode = _enumByName(
      ReaderLongPressMoveMode.values,
      values['longPressZoomMoveMode'],
      _longPressZoomMoveMode,
    );
    _longPressZoomPanRatio = _doubleValue(
      values['longPressZoomPanRatio'],
      _longPressZoomPanRatio,
      min: 0.25,
      max: 4,
    );
    _longPressZoomLimitToViewport = _boolValue(
      values['longPressZoomLimitToViewport'],
      _longPressZoomLimitToViewport,
    );
    _doubleTapZoomOrigin = _enumByName(
      ReaderDoubleTapZoomOrigin.values,
      values['doubleTapZoomOrigin'],
      _doubleTapZoomOrigin,
    );
    _zoomDecodeBoostEnabled =
        _boolValue(values['zoomDecodeBoost'], _zoomDecodeBoostEnabled);
    _detailsPreviewMaxItemsPerRow = _intInRange(
      values['detailsPreviewMaxItemsPerRow'],
      fallback: _detailsPreviewMaxItemsPerRow,
      min: 1,
      max: 8,
    );
    _networkUserAgent = _networkUserAgentValue(
      values['networkUserAgent'],
      fallback: _networkUserAgent,
    );
    final debugTraceExportDirectory = values['debugTraceExportDirectory'];
    if (debugTraceExportDirectory is String) {
      _debugTraceExportDirectory = normalizeDebugTraceExportDirectory(
        debugTraceExportDirectory,
      );
    }
    _chapterDownloadDirectoryOverride = _nullableTrimmedString(
      values['chapterDownloadDirectoryOverride'],
    );
    _chapterDownloadDirectoryPendingMoveFrom = _nullableTrimmedString(
      values['chapterDownloadDirectoryPendingMoveFrom'],
    );
    _cacheLimitMb = _intInRange(
      values['cacheLimitMb'],
      fallback: _cacheLimitMb,
      min: minCacheLimitMb,
      max: maxCacheLimitMb,
    );
    _readerPrefetchReadBudgetMiB = _intInRange(
      values['readerPrefetchReadBudgetMiB'],
      fallback: _readerPrefetchReadBudgetMiB,
      min: minReaderPrefetchReadBudgetMiB,
      max: maxReaderPrefetchReadBudgetMiB,
    );
    _cachedCarrierTrustMode = _enumByName(
      CachedCarrierTrustMode.values,
      values['cachedCarrierTrustMode'],
      _cachedCarrierTrustMode,
    );
    _pluginTrustConflictingHistoricalCarriers = _decodeBoolMap(
      values['pluginTrustConflictingHistoricalCarriers'],
    );
    _sourceDownloadDirectories = _decodeDirectoryMap(
      values['sourceDownloadDirectories'],
    );
    _sourceSearchHistory = _decodeSearchHistory(
      values['sourceSearchHistory'],
    );
    _acknowledgedComicVersionNotices = _decodeIdentitySet(
      values['acknowledgedComicVersionNotices'],
      maxItems: 512,
    );
    _comicReaderSettings = _decodeComicReaderSettings(
      values['comicReaderSettings'],
    );
    if (!_disposed) {
      _attached = true;
      if (_themeMode != priorThemeMode ||
          _amoledDarkTheme != priorAmoledDarkTheme) {
        _themeChanges.notifyListeners();
      }
      notifyListeners();
    }
  }

  void setThemeMode(ThemeMode value) {
    if (_disposed || _themeMode == value) return;
    _themeMode = value;
    _themeChanges.notifyListeners();
    _changed();
  }

  void setAmoledDarkTheme(bool value) {
    if (_disposed || _amoledDarkTheme == value) return;
    _amoledDarkTheme = value;
    _themeChanges.notifyListeners();
    _changed();
  }

  void setDebugTraceEnabled(bool value) {
    if (_disposed || _debugTraceEnabled == value) return;
    _debugTraceEnabled = value;
    _changed();
  }

  void setDebugTraceExportDirectory(String value) {
    final normalized = normalizeDebugTraceExportDirectory(value);
    if (_disposed || _debugTraceExportDirectory == normalized) return;
    _debugTraceExportDirectory = normalized;
    _changed();
  }

  void setShelfSourceFilter(ShelfSourceFilter value) {
    if (_disposed || _shelfSourceFilter == value) return;
    _shelfSourceFilter = value;
    _changed();
  }

  void setShelfSortMode(LibrarySortMode value) {
    if (_disposed || _shelfSortMode == value) return;
    _shelfSortMode = value;
    _changed();
  }

  void setShelfView(ShelfViewPreference value) {
    if (_disposed || _shelfView == value) return;
    _shelfView = value;
    _changed();
  }

  void setDefaultReaderMode(ReaderMode value) {
    if (_disposed || _defaultReaderMode == value) return;
    _defaultReaderMode = value;
    _changed();
  }

  void setReaderStartsImmersive(bool value) {
    if (_disposed || _readerStartsImmersive == value) return;
    _readerStartsImmersive = value;
    _changed();
  }

  void setAdaptiveReaderEnabled(bool value) {
    if (_disposed || _adaptiveReaderEnabled == value) return;
    _adaptiveReaderEnabled = value;
    _changed();
  }

  void setDefaultVerticalStitch(bool value) {
    if (_disposed || _defaultVerticalStitch == value) return;
    _defaultVerticalStitch = value;
    _changed();
  }

  void setDefaultZoomStageFirst(double value) {
    final clamped = value.clamp(1.1, 8.0).toDouble();
    if (_disposed || _defaultZoomStageFirst == clamped) return;
    _defaultZoomStageFirst = clamped;
    if (_defaultZoomStageSecond < clamped) {
      _defaultZoomStageSecond = clamped;
    }
    _changed();
  }

  void setDefaultZoomStageSecond(double value) {
    final clamped = value.clamp(1.1, 8.0).toDouble();
    if (_disposed || _defaultZoomStageSecond == clamped) return;
    _defaultZoomStageSecond = math.max(clamped, _defaultZoomStageFirst);
    _changed();
  }

  void setLongPressZoomEnabled(bool value) {
    if (_disposed || _longPressZoomEnabled == value) return;
    _longPressZoomEnabled = value;
    _changed();
  }

  void setLongPressZoomRestoreOnRelease(bool value) {
    if (_disposed || _longPressZoomRestoreOnRelease == value) return;
    _longPressZoomRestoreOnRelease = value;
    _changed();
  }

  void setLongPressZoomMoveMode(ReaderLongPressMoveMode value) {
    if (_disposed || _longPressZoomMoveMode == value) return;
    _longPressZoomMoveMode = value;
    _changed();
  }

  void setLongPressZoomPanRatio(double value) {
    final clamped = value.clamp(0.25, 4.0).toDouble();
    if (_disposed || _longPressZoomPanRatio == clamped) return;
    _longPressZoomPanRatio = clamped;
    _changed();
  }

  void setLongPressZoomLimitToViewport(bool value) {
    if (_disposed || _longPressZoomLimitToViewport == value) return;
    _longPressZoomLimitToViewport = value;
    _changed();
  }

  void setDoubleTapZoomOrigin(ReaderDoubleTapZoomOrigin value) {
    if (_disposed || _doubleTapZoomOrigin == value) return;
    _doubleTapZoomOrigin = value;
    _changed();
  }

  void setZoomDecodeBoostEnabled(bool value) {
    if (_disposed || _zoomDecodeBoostEnabled == value) return;
    _zoomDecodeBoostEnabled = value;
    _changed();
  }

  void setDetailsPreviewMaxItemsPerRow(int value) {
    final normalized = value.clamp(1, 8).toInt();
    if (_disposed || _detailsPreviewMaxItemsPerRow == normalized) return;
    _detailsPreviewMaxItemsPerRow = normalized;
    _changed();
  }

  void setNetworkUserAgent(String value) {
    final normalized = _networkUserAgentValue(
      value,
      fallback: defaultNetworkUserAgent,
    );
    if (_disposed || _networkUserAgent == normalized) return;
    _networkUserAgent = normalized;
    _changed();
  }

  void resetNetworkUserAgent() => setNetworkUserAgent(defaultNetworkUserAgent);

  void setChapterDownloadDirectoryOverride(String? value) {
    final normalized = _nullableTrimmedString(value);
    if (_disposed || _chapterDownloadDirectoryOverride == normalized) return;
    _chapterDownloadDirectoryOverride = normalized;
    _changed();
  }

  void setChapterDownloadDirectoryPendingMoveFrom(String? value) {
    final normalized = _nullableTrimmedString(value);
    if (_disposed || _chapterDownloadDirectoryPendingMoveFrom == normalized) {
      return;
    }
    _chapterDownloadDirectoryPendingMoveFrom = normalized;
    _changed();
  }

  void setCacheLimitMb(int value) {
    final clamped =
        value.clamp(minCacheLimitMb, maxCacheLimitMb).toInt();
    if (_disposed || _cacheLimitMb == clamped) return;
    _cacheLimitMb = clamped;
    _changed();
  }

  void setReaderPrefetchReadBudgetMiB(int value) {
    final clamped = value
        .clamp(
          minReaderPrefetchReadBudgetMiB,
          maxReaderPrefetchReadBudgetMiB,
        )
        .toInt();
    if (_disposed || _readerPrefetchReadBudgetMiB == clamped) return;
    _readerPrefetchReadBudgetMiB = clamped;
    _changed();
  }

  void setCachedCarrierTrustMode(CachedCarrierTrustMode value) {
    if (_disposed || _cachedCarrierTrustMode == value) return;
    _cachedCarrierTrustMode = value;
    _changed();
  }

  void setPluginTrustConflictingHistoricalCarriers(
    String pluginId,
    bool value,
  ) {
    if (_disposed) return;
    final key = pluginId.trim();
    if (key.isEmpty) return;
    final current = _pluginTrustConflictingHistoricalCarriers[key] ?? false;
    if (current == value) return;
    final next = <String, bool>{..._pluginTrustConflictingHistoricalCarriers};
    if (value) {
      next[key] = true;
    } else {
      next.remove(key);
    }
    _pluginTrustConflictingHistoricalCarriers = next;
    _changed();
  }

  /// Sets or clears (null/empty) the physical download root of one source.
  void setSourceDownloadDirectory(String sourceId, String? directory) {
    if (_disposed) return;
    final key = sourceId.trim();
    if (key.isEmpty) return;
    final normalized = _nullableTrimmedString(directory);
    if (normalized == null) {
      if (!_sourceDownloadDirectories.containsKey(key)) return;
      _sourceDownloadDirectories = <String, String>{
        ..._sourceDownloadDirectories,
      }..remove(key);
      _changed();
      return;
    }
    if (_sourceDownloadDirectories[key] == normalized) return;
    _sourceDownloadDirectories = <String, String>{
      ..._sourceDownloadDirectories,
      key: normalized,
    };
    _changed();
  }

  void rememberSourceSearch(String value) {
    final normalized = value.trim();
    if (_disposed || normalized.isEmpty) return;
    final next = <String>[
      normalized,
      for (final item in _sourceSearchHistory)
        if (item.toLowerCase() != normalized.toLowerCase()) item,
    ];
    if (next.length > 20) {
      next.removeRange(20, next.length);
    }
    if (_sameStrings(next, _sourceSearchHistory)) return;
    _sourceSearchHistory = next;
    _changed();
  }

  void removeSourceSearch(String value) {
    if (_disposed) return;
    final next = _sourceSearchHistory
        .where((item) => item != value)
        .toList(growable: false);
    if (_sameStrings(next, _sourceSearchHistory)) return;
    _sourceSearchHistory = next;
    _changed();
  }

  void clearSourceSearchHistory() {
    if (_disposed || _sourceSearchHistory.isEmpty) return;
    _sourceSearchHistory = <String>[];
    _changed();
  }

  bool hasAcknowledgedComicVersionNotice(
    String sourceId,
    String predecessorComicId,
    String successorComicId,
  ) =>
      _acknowledgedComicVersionNotices.contains(
        comicVersionNoticeIdentity(
          sourceId,
          predecessorComicId,
          successorComicId,
        ),
      );

  void acknowledgeComicVersionNotice(
    String sourceId,
    String predecessorComicId,
    String successorComicId,
  ) {
    if (_disposed) return;
    final identity = comicVersionNoticeIdentity(
      sourceId,
      predecessorComicId,
      successorComicId,
    );
    if (_acknowledgedComicVersionNotices.contains(identity)) return;
    final next = <String>{..._acknowledgedComicVersionNotices, identity};
    while (next.length > 512) {
      next.remove(next.first);
    }
    _acknowledgedComicVersionNotices = next;
    _changed();
  }

  void setComicReaderSettings(
    String sourceId,
    String comicId,
    ComicReaderSettings settings,
  ) {
    if (_disposed) return;
    final identity = comicReaderSettingsIdentity(sourceId, comicId);
    if (_comicReaderSettings[identity] == settings) return;
    final next = <String, ComicReaderSettings>{
      ..._comicReaderSettings,
      identity: settings,
    };
    while (next.length > 512) {
      next.remove(next.keys.first);
    }
    _comicReaderSettings = next;
    _changed();
  }

  void clearComicReaderSettings(String sourceId, String comicId) {
    if (_disposed) return;
    final identity = comicReaderSettingsIdentity(sourceId, comicId);
    if (!_comicReaderSettings.containsKey(identity)) return;
    _comicReaderSettings = <String, ComicReaderSettings>{
      ..._comicReaderSettings,
    }..remove(identity);
    _changed();
  }

  Future<void> flush() => _writeTail;

  void _changed() {
    if (_disposed) return;
    _revision++;
    notifyListeners();
    _schedulePersist();
  }

  void _schedulePersist() {
    if (_write == null) return;
    unawaited(_queuePersist());
  }

  Future<void> _queuePersist() {
    _writeTail = _writeTail.then((_) => _persist()).catchError(
      (Object error, StackTrace stackTrace) {
        debugPrint('app preferences persistence failed: $error');
      },
    );
    return _writeTail;
  }

  Future<void> _persist() async {
    final write = _write;
    if (write == null) return;
    await write(<String, Object?>{
      'version': 7,
      'themeMode': _themeMode.name,
      'amoledDarkTheme': _amoledDarkTheme,
      'debugTraceEnabled': _debugTraceEnabled,
      'shelfSourceFilter': _shelfSourceFilter.name,
      'shelfSortMode': _shelfSortMode.name,
      'shelfView': _shelfView.name,
      'defaultReaderMode': _defaultReaderMode.name,
      'readerStartsImmersive': _readerStartsImmersive,
      'adaptiveReaderEnabled': _adaptiveReaderEnabled,
      'defaultVerticalStitch': _defaultVerticalStitch,
      'defaultZoomStage1': _defaultZoomStageFirst,
      'defaultZoomStage2': _defaultZoomStageSecond,
      'doubleTapZoomOrigin': _doubleTapZoomOrigin.name,
      'longPressZoomEnabled': _longPressZoomEnabled,
      'longPressZoomRestoreOnRelease': _longPressZoomRestoreOnRelease,
      'longPressZoomMoveMode': _longPressZoomMoveMode.name,
      'longPressZoomPanRatio': _longPressZoomPanRatio,
      'longPressZoomLimitToViewport': _longPressZoomLimitToViewport,
      'zoomDecodeBoost': _zoomDecodeBoostEnabled,
      'detailsPreviewMaxItemsPerRow': _detailsPreviewMaxItemsPerRow,
      'networkUserAgent': _networkUserAgent,
      'debugTraceExportDirectory': _debugTraceExportDirectory,
      'chapterDownloadDirectoryOverride': _chapterDownloadDirectoryOverride,
      'chapterDownloadDirectoryPendingMoveFrom':
          _chapterDownloadDirectoryPendingMoveFrom,
      'cacheLimitMb': _cacheLimitMb,
      'readerPrefetchReadBudgetMiB': _readerPrefetchReadBudgetMiB,
      'cachedCarrierTrustMode': _cachedCarrierTrustMode.name,
      'pluginTrustConflictingHistoricalCarriers':
          _pluginTrustConflictingHistoricalCarriers,
      'sourceDownloadDirectories': _sourceDownloadDirectories,
      'sourceSearchHistory': _sourceSearchHistory,
      'acknowledgedComicVersionNotices':
          _acknowledgedComicVersionNotices.toList(growable: false),
      'comicReaderSettings': <String, Object?>{
        for (final entry in _comicReaderSettings.entries)
          entry.key: entry.value.toJson(),
      },
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _themeChanges.dispose();
    super.dispose();
  }
}

T _enumByName<T extends Enum>(
  List<T> values,
  Object? raw,
  T fallback,
) {
  if (raw is! String) return fallback;
  for (final value in values) {
    if (value.name == raw) return value;
  }
  return fallback;
}

T? _nullableEnumByName<T extends Enum>(List<T> values, Object? raw) {
  if (raw is! String) return null;
  for (final value in values) {
    if (value.name == raw) return value;
  }
  return null;
}

Map<String, ComicReaderSettings> _decodeComicReaderSettings(Object? raw) {
  if (raw is! Map) return <String, ComicReaderSettings>{};
  final result = <String, ComicReaderSettings>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    final value = entry.value;
    if (key is! String || value is! Map) continue;
    try {
      result[key] = ComicReaderSettings.fromJson(
        Map<String, Object?>.from(value),
      );
    } on Object {
      // One malformed per-comic override must not discard the remaining
      // application preferences.
    }
  }
  return result;
}

bool _boolValue(Object? raw, bool fallback) => raw is bool ? raw : fallback;

double _doubleValue(
  Object? raw,
  double fallback, {
  required double min,
  required double max,
}) {
  if (raw is num) {
    final parsed = raw.toDouble();
    if (parsed.isFinite) return parsed.clamp(min, max).toDouble();
  }
  return fallback;
}

String _networkUserAgentValue(Object? raw, {required String fallback}) {
  if (raw is! String) return fallback;
  final normalized = raw.trim();
  return normalized.isEmpty ? defaultNetworkUserAgent : normalized;
}

String? _nullableTrimmedString(Object? raw) {
  if (raw is! String) return null;
  final normalized = raw.trim();
  return normalized.isEmpty ? null : normalized;
}

Map<String, String> _decodeDirectoryMap(Object? raw) {
  if (raw is! Map) return <String, String>{};
  final result = <String, String>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    if (key is! String || key.trim().isEmpty) continue;
    final value = entry.value;
    if (value is! String || value.trim().isEmpty) continue;
    result[key] = value.trim();
  }
  return result;
}

Map<String, bool> _decodeBoolMap(Object? raw) {
  if (raw is! Map) return <String, bool>{};
  final result = <String, bool>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    if (key is! String || key.trim().isEmpty || entry.value is! bool) continue;
    if (entry.value == true) result[key.trim()] = true;
  }
  return result;
}


int _intInRange(
  Object? raw, {
  required int fallback,
  required int min,
  required int max,
}) {
  final value = raw is int ? raw : fallback;
  return value.clamp(min, max).toInt();
}

List<String> _decodeSearchHistory(Object? raw) {
  if (raw is! List) return <String>[];
  final result = <String>[];
  for (final value in raw) {
    if (value is! String) continue;
    final normalized = value.trim();
    if (normalized.isEmpty ||
        result.any((item) => item.toLowerCase() == normalized.toLowerCase())) {
      continue;
    }
    result.add(normalized);
    if (result.length == 20) break;
  }
  return result;
}

Set<String> _decodeIdentitySet(
  Object? raw, {
  required int maxItems,
}) {
  if (raw is! List) return <String>{};
  final result = <String>{};
  for (final value in raw) {
    if (value is! String || value.isEmpty) continue;
    result.add(value);
    if (result.length == maxItems) break;
  }
  return result;
}

bool _sameStrings(List<String> left, List<String> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

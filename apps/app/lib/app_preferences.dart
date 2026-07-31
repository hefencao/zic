import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';

enum ShelfSourceFilter { all, local, remote }

enum ShelfViewPreference { gallery, list }

/// Application-level preferences that are safe for Presentation to observe.
///
/// This controller owns only small user choices. It does not own cache files,
/// downloads, Reader sessions, network transports, or plugin storage.
final class AppPreferencesController extends ChangeNotifier {
  AppPreferencesController();

  ThemeMode _themeMode = ThemeMode.dark;
  bool _debugTraceEnabled = true;
  ShelfSourceFilter _shelfSourceFilter = ShelfSourceFilter.all;
  LibrarySortMode _shelfSortMode = LibrarySortMode.recent;
  ShelfViewPreference _shelfView = ShelfViewPreference.gallery;
  ReaderMode _defaultReaderMode = ReaderMode.paged;
  bool _readerStartsImmersive = true;
  Future<void> Function(Map<String, Object?> values)? _write;
  Future<void> _writeTail = Future<void>.value();
  int _revision = 0;
  bool _disposed = false;

  ThemeMode get themeMode => _themeMode;
  bool get debugTraceEnabled => _debugTraceEnabled;
  ShelfSourceFilter get shelfSourceFilter => _shelfSourceFilter;
  LibrarySortMode get shelfSortMode => _shelfSortMode;
  ShelfViewPreference get shelfView => _shelfView;
  ReaderMode get defaultReaderMode => _defaultReaderMode;
  bool get readerStartsImmersive => _readerStartsImmersive;

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
      }
      rethrow;
    }
    if (_disposed) return;
    _write = write;
    if (_revision != revisionAtStart || values == null) {
      await _queuePersist();
      return;
    }
    _themeMode = _enumByName(
      ThemeMode.values,
      values['themeMode'],
      _themeMode,
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
    if (!_disposed) notifyListeners();
  }

  void setThemeMode(ThemeMode value) {
    if (_disposed || _themeMode == value) return;
    _themeMode = value;
    _changed();
  }

  void setDebugTraceEnabled(bool value) {
    if (_disposed || _debugTraceEnabled == value) return;
    _debugTraceEnabled = value;
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
      'version': 1,
      'themeMode': _themeMode.name,
      'debugTraceEnabled': _debugTraceEnabled,
      'shelfSourceFilter': _shelfSourceFilter.name,
      'shelfSortMode': _shelfSortMode.name,
      'shelfView': _shelfView.name,
      'defaultReaderMode': _defaultReaderMode.name,
      'readerStartsImmersive': _readerStartsImmersive,
    });
  }

  @override
  void dispose() {
    _disposed = true;
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

bool _boolValue(Object? raw, bool fallback) => raw is bool ? raw : fallback;

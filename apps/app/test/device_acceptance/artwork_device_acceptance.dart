import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:telemetry/telemetry.dart';
import 'package:zic/debug_trace.dart';
import 'package:zic/debug_trace_export.dart';
import 'package:zic/source_browser.dart';
import 'package:zic/source_resource_gateway.dart';

// Explicit device fixture: production widgets and gateway, isolated in-memory
// source/cache. It never opens the user's library, preferences or artifact index.
final _trace = DebugTraceLog();
final _checks = <Map<String, Object?>>[];
final _browserKey = GlobalKey();
final _rebuild = ValueNotifier<int>(0);
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
  'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final source = _ArtworkFixtureSource();
  final cache = ResourceCacheManager();
  final gateway = ComicSourceResourceGateway(sourceForId: (_) => source);
  runApp(MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('隔离封面故障验收')),
      body: ValueListenableBuilder<int>(
        valueListenable: _rebuild,
        builder: (_, revision, _) => ComicSourcesPage(
          key: _browserKey,
          sources: <BrowsableComicSource>[source],
          activeSourceId: source.sourceId,
          onSourceSelected: (_) {},
          queryRevision: revision,
          traceSink: _trace,
          loadCover: (_, comic, uri, {bool forceRefresh = false}) => gateway.loadArtworkSource(
            cache: cache,
            sourceId: source.sourceId,
            comicId: comic.comicId,
            cacheComicId: source.canonicalComicIdentity(comic.comicId),
            uri: uri,
            forceRefresh: forceRefresh,
          ),
          onOpenComic: (_, comic) async {
            source.openedComicId = comic.comicId;
          },
        ),
      ),
    ),
  ));
  var completed = false;
  try {
    await _frames(40);
    _check('source-failure-typed',
      _stage('cover-source-failed').single.payload['errorCode'] == 'source');
    _check('decoder-failure-separated',
      _stage('cover-decode-failed').single.payload['failureLayer'] ==
        'presentation-decode');
    _check('offscreen-source-not-started', !source.calls.containsKey('comic-23'));
    final decodeFailures = _stage('cover-decode-failed').length;
    _rebuild.value++;
    await _frames(20);
    await Future<void>.delayed(const Duration(seconds: 3));
    _check('mounted-failures-do-not-retry', source.calls['comic-0'] == 1 &&
      source.calls['comic-1'] == 1 &&
      _stage('cover-source-failed').length == 1 &&
      _stage('cover-decode-failed').length == decodeFailures);

    final scroll = _scrollPosition();
    scroll.jumpTo(scroll.maxScrollExtent);
    await _frames(30);
    _check('failed-card-really-unmounted', !_hasCard('comic-0'));
    _check('pending-offscreen-demand-single', source.calls['comic-23'] == 1 &&
      !source.pending.isCompleted);
    scroll.jumpTo(0);
    await _frames(30);
    _check('source-failure-remount-does-not-retry', _hasCard('comic-0') &&
      source.calls['comic-0'] == 1 &&
      _stage('cover-source-failed').length == 1);
    _check('decoder-failure-remount-does-not-reacquire',
      _hasCard('comic-1') && source.calls['comic-1'] == 1);
    source.pending.complete(_png);
    await _frames(20);
    _check('unpainted-source-completion-does-not-retry',
      source.calls['comic-23'] == 1);
    _check('offscreen-ready-source-not-painted', !_hasCard('comic-23') &&
      !_stage('cover-first-frame').any(
        (event) => event.identityHash?.endsWith('comic-23') ?? false));
    scroll.jumpTo(scroll.maxScrollExtent);
    await _frames(30);
    _check('offscreen-ready-source-paints-after-demand', _hasCard('comic-23') &&
      source.calls['comic-23'] == 1 && _stage('cover-first-frame').any(
        (event) => event.identityHash?.endsWith('comic-23') ?? false));
    scroll.jumpTo(0);
    await _frames(30);

    final healthyCalls = source.calls['comic-2'];
    source.recovered = true;
    await _refreshState().show();
    await _frames(30);
    _check('explicit-refresh-recovers-source-failure',
      source.calls['comic-0'] == 2 && _stage('cover-first-frame').any(
        (event) => event.identityHash?.endsWith('comic-0') ?? false));
    _check('explicit-refresh-replaces-corrupt-encoded-response',
      source.calls['comic-1'] == 2 && _stage('cover-first-frame').any(
        (event) => event.identityHash?.endsWith('comic-1') ?? false));
    _check('explicit-refresh-preserves-other-encoded-cache',
      healthyCalls == 1 && source.calls['comic-2'] == healthyCalls);
    await _refreshState().show();
    await _frames(30);
    _check('successful-recovery-does-not-repeat-forced-source-request',
      source.calls['comic-0'] == 2 && source.calls['comic-1'] == 2 &&
      source.calls['comic-2'] == healthyCalls);

    final originalCard = _cardElement('comic-2');
    final originalImageState = _imageState('comic-2');
    source.aliasSecond = true;
    _rebuild.value++;
    await _frames(30);
    _check('canonical-alias-preserves-card-and-image-state',
      identical(_cardElement('comic-2'), originalCard) &&
      identical(_imageState('comic-2'), originalImageState) &&
      originalImageState.mounted);
    _check('canonical-alias-does-not-reload-cover',
      source.calls['comic-2'] == healthyCalls);
    (_cardElement('comic-2').widget as InkWell).onTap!();
    await _frames(2);
    _check('canonical-card-command-keeps-latest-raw-locator',
      source.openedComicId == 'comic-2-raw-alias');

    source.duplicateSecond = true;
    _rebuild.value++;
    await _frames(30);
    _check('canonical-duplicate-page-has-one-card', _cardCount('comic-2') == 1);
    _check('canonical-duplicate-page-preserves-image-and-source',
      identical(_imageState('comic-2'), originalImageState) &&
      originalImageState.mounted && source.calls['comic-2'] == healthyCalls);
    (_cardElement('comic-2').widget as InkWell).onTap!();
    await _frames(2);
    _check('canonical-duplicate-keeps-first-source-ordered-command',
      source.openedComicId == 'comic-2-raw-alias');
    (_element((element) => element.widget.key == comicSourceNextPageKey)!
      .widget as IconButton).onPressed!();
    await _frames(30);
    _check('canonical-duplicate-fallback-uses-raw-page-count',
      source.browseOffsets.last == 25);
    source.explicitNextOffset = 24;
    (_element((element) => element.widget.key == comicSourcePreviousPageKey)!
      .widget as IconButton).onPressed!();
    await _frames(30);
    (_element((element) => element.widget.key == comicSourceNextPageKey)!
      .widget as IconButton).onPressed!();
    await _frames(30);
    _check('canonical-duplicate-preserves-native-next-offset',
      source.browseOffsets.last == 24);
    completed = true;
  } on Object catch (error) {
    _checks.add(<String, Object?>{
      'step': 'fixture', 'status': 'failed', 'error': error.toString(),
    });
  } finally {
    final result = <String, Object?>{
      'completed': completed,
      'boundary': 'Production SourceBrowser/StableArtworkImage/gateway/cache; '
          'isolated fixture, no real origin or durable-store failure claims.',
      'checks': _checks,
      'sourceCalls': source.calls,
      'browseOffsets': source.browseOffsets,
      'trace': _trace.exportEvents.map((event) => event.toJson()).toList(),
      'limits': <String>[
        'Decoder failure is checked across mounted rebuild/idle, not claimed '
            'terminal across a new presentation mount.',
        'Controlled memory-cache repair does not claim real-origin or '
            'durable-store corruption acceptance.',
      ],
    };
    await exportDebugTraceFile(
      suggestedName: 'zic-artwork-acceptance-'
          '${DateTime.now().millisecondsSinceEpoch}.json',
      bytes: Uint8List.fromList(utf8.encode(jsonEncode(result))),
      relativeDirectory: 'Debug',
    );
    runApp(MaterialApp(home: Scaffold(
      body: Center(child: Text(completed ? '封面故障验收完成' : '封面故障验收失败')),
    )));
    await _frames(2);
    gateway.close();
    await cache.close();
  }
}

Future<void> _frames(int count) async {
  for (var index = 0; index < count; index++) {
    await WidgetsBinding.instance.endOfFrame;
  }
}

List<TraceEvent> _stage(String stage) => _trace.exportEvents
    .where((event) => event.payload['stage'] == stage).toList();

void _check(String step, bool passed) {
  _checks.add(<String, Object?>{'step': step, 'status': passed ? 'passed' : 'failed'});
  if (!passed) throw StateError(step);
}

Element? _element(bool Function(Element element) matches, {Element? within}) {
  Element? found;
  void visit(Element element) {
    if (found != null) return;
    if (matches(element)) { found = element; return; }
    element.visitChildren(visit);
  }
  visit(within ?? _browserKey.currentContext! as Element);
  return found;
}

bool _hasCard(String comicId) => _element((element) =>
    element.widget.key == sourceComicCardKey('fixture-artwork', comicId)) != null;

Element _cardElement(String canonicalComicId) => _element((element) =>
    element.widget.key ==
      sourceComicCardKey('fixture-artwork', canonicalComicId))!;

int _cardCount(String canonicalComicId) {
  var count = 0;
  void visit(Element element) {
    if (element.widget.key ==
        sourceComicCardKey('fixture-artwork', canonicalComicId)) count++;
    element.visitChildren(visit);
  }
  visit(_browserKey.currentContext! as Element);
  return count;
}

State<StatefulWidget> _imageState(String canonicalComicId) =>
    (_element((element) => element.widget is Image,
      within: _cardElement(canonicalComicId))! as StatefulElement).state;

ScrollPosition _scrollPosition() {
  final element = _element((element) => element.widget is Scrollable &&
    (element.widget as Scrollable).axisDirection == AxisDirection.down);
  return ((element! as StatefulElement).state as ScrollableState).position;
}

RefreshIndicatorState _refreshState() =>
    (_element((element) => element.widget is RefreshIndicator)!
      as StatefulElement).state as RefreshIndicatorState;

final class _ArtworkFixtureSource
    implements BrowsableComicSource, CanonicalComicIdentitySource {
  final calls = <String, int>{};
  final pending = Completer<Uint8List>();
  bool recovered = false;
  bool aliasSecond = false;
  bool duplicateSecond = false;
  int? explicitNextOffset;
  final browseOffsets = <int>[];
  String? openedComicId;

  @override
  String canonicalComicIdentity(String comicId) =>
      comicId == 'comic-2-raw-alias' ? 'comic-2' : comicId;

  @override
  String get sourceId => 'fixture-artwork';
  @override
  ComicSourceDescriptor get descriptor => ComicSourceDescriptor(
    sourceId: 'fixture-artwork', name: '封面故障源', language: 'Test',
    website: Uri.https('fixture.invalid', '/'),
  );
  @override
  Future<SourceBrowsePage> browse({String query = '', int offset = 0,
      int limit = 24}) async {
    browseOffsets.add(offset);
    return SourceBrowsePage(
      offset: offset, hasMore: duplicateSecond && offset == 0,
      nextOffset: duplicateSecond && offset == 0 ? explicitNextOffset : null,
      items: <SourceComicSummary>[
        for (var index = 0; index < 24; index++) SourceComicSummary(
          sourceId: sourceId,
          comicId: aliasSecond && index == 2 ? 'comic-2-raw-alias' : 'comic-$index',
          title: '封面 $index',
          authors: const <String>[],
          coverUri: Uri.parse('fixture:comic-$index'),
        ),
        if (duplicateSecond) SourceComicSummary(
          sourceId: sourceId,
          comicId: 'comic-2',
          title: '重复别名 2',
          authors: const <String>[],
          coverUri: Uri.parse('fixture:comic-2'),
        ),
      ],
    );
  }
  @override
  Future<Uint8List> loadResource(Uri uri) async {
    final comicId = uri.path;
    calls.update(comicId, (count) => count + 1, ifAbsent: () => 1);
    if (comicId == 'comic-0' && !recovered) {
      throw Failure(code: ErrorCode.source, message: 'terminal source fixture');
    }
    if (comicId == 'comic-1' && !recovered) {
      return Uint8List.sublistView(_png, 0, 24);
    }
    if (comicId == 'comic-23') return pending.future;
    return _png;
  }
  @override
  Future<ComicManifest> loadComic(String comicId) =>
      throw UnsupportedError('fixture does not open details');
  @override
  Future<ChapterManifest> loadChapter(String chapterId) =>
      throw UnsupportedError('fixture does not open Reader');
}

part of 'source_device_acceptance.dart';

// Inspect the actual source plan before executing its unmodified media path.
// Cleartext capability is domain-independent; retain old-host matching only as
// an observation, never as an eligibility gate or a reason to rewrite a URL.
Future<void> _probeCleartextMedia() async {
  final support = (await getStartupApplicationSupportPath())!;
  final userRoot = await getDefaultZicStorageRoot(
    applicationSupportPath: getStartupApplicationSupportPath,
  );
  _results = File('$support/zic-source-acceptance-results.json');
  await _results.writeAsString('[]', flush: true);
  final originalManifest = File('$userRoot/external_plugins/installed.json');
  final manifestBytes = await originalManifest.readAsBytes();
  final manifest = jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
  final record = (manifest['plugins'] as List).cast<Map<String, dynamic>>().singleWhere(
    (row) => row['packageName'] == 'eu.kanade.tachiyomi.extension.zh.wnacg');
  final originalPayload = File(record['payloadPath'] as String);
  final payloadBytes = await originalPayload.readAsBytes();
  final root = await Directory(support).createTemp('zic-source-cleartext-');
  final coordinator = DownloadResourceCoordinator();
  final transport = ExternalPluginResourceTransportPool(
    directTransport: RhttpSourceResourceDirectTransport(preparePlatform: prepareRhttpPlatform),
  );
  ExternalPluginController? controller;
  var outcome = 'unverified';
  try {
    final payloadRoot = await Directory('${root.path}/external_plugins').create();
    record['payloadPath'] = (await originalPayload.copy('${payloadRoot.path}/wnacg.apk')).path;
    manifest['plugins'] = <Map<String, dynamic>>[record];
    await File('${payloadRoot.path}/installed.json').writeAsString(jsonEncode(manifest), flush: true);
    controller = await ExternalPluginController.openDeferred(root.path,
      discoverDeviceMihonExtensions: false, deferRuntimeActivation: true);
    await controller.ready;
    final source = controller.activeSources.singleWhere(
      (item) => item.sourceId == 'mihon:6551136894818591762');
    final browse = await source.browse();
    if (browse.items.isEmpty) {
      await _record(<String, Object?>{'step': 'input', 'status': 'unverified',
        'reason': 'current list has no media sample'});
      return;
    }
    final sample = browse.items.first;
    final comic = await source.loadComic(sample.comicId);
    if (sample.coverUri == null || comic.chapters.isEmpty) { return; }
    final chapter = await source.loadChapter(comic.chapters.first.chapterId);
    if (chapter.pages.isEmpty) { return; }
    final locators = <String, Uri>{'cover': sample.coverUri!, 'page': chapter.pages.first.uri};
    final plans = <String, ComicResourceRequest>{};
    for (final entry in locators.entries) {
      final plan = await _withProbeControl(coordinator, (control) =>
        (source as ControlledResolvableComicResourceSource)
            .resolveResourceControlled(entry.value, control: control));
      plans[entry.key] = plan;
      await _record(<String, Object?>{'step': '${entry.key}-origin', 'status': 'observed',
        'scheme': plan.uri.scheme,
        'matches_original_host_family': RegExp(r'^img[^.]*\.wnimg[^.]*\.ru$')
            .hasMatch(plan.uri.host.toLowerCase()),
        'requires_runtime_transform': plan.requiresRuntimeTransform});
    }
    if (plans.values.any((plan) => plan.uri.scheme != 'http')) {
      await _record(<String, Object?>{'step': 'input', 'status': 'unverified',
        'reason': 'current sample does not provide both real cleartext origins'});
      return;
    }
    for (final entry in locators.entries) {
      final media = await _readMedia(source, entry.value, transport, coordinator);
      if ((media['bytes'] as int) <= 0 || (media['width'] as int) <= 0 ||
          (media['height'] as int) <= 0) { throw StateError('source media is not renderable'); }
      await _record(<String, Object?>{'step': '${entry.key}-media', 'status': 'passed',
        ...media, 'actual_unmodified_cleartext_plan': true});
    }
    outcome = 'passed';
  } on Object catch (error) {
    outcome = 'failed';
    await _record(<String, Object?>{'step': 'failure', 'status': 'failed',
      'diagnostics': _failureDiagnostics(error)});
  } finally {
    var clean = true;
    for (final action in <Future<void> Function()>[
      () async { coordinator.networkLane.cancelAll(); await coordinator.networkLane.idle(); },
      () async { transport.close(); },
      () async { await controller?.close(); },
      () async { await root.delete(recursive: true); },
    ]) {
      try { await action(); }
      on Object catch (error) {
        clean = false;
        await _record(<String, Object?>{'step': 'cleanup', 'status': 'failed',
          'diagnostics': _failureDiagnostics(error)});
      }
    }
    final originalsUnchanged = _probeBytesEqual(manifestBytes, await originalManifest.readAsBytes()) &&
        _probeBytesEqual(payloadBytes, await originalPayload.readAsBytes());
    await _record(<String, Object?>{'step': 'complete',
      'status': clean && originalsUnchanged ? outcome : 'failed',
      'user_installed_files_unchanged': originalsUnchanged,
      'user_library_or_artifact_index_opened': false,
      'cleanup_succeeded': clean, 'temporary_directory_removed': !await root.exists()});
  }
}

// Opt-in contract probes use the existing isolated controller and NetLane.
// Source model/header/body values remain in memory; output contains assertions
// and public installation metadata only. No user catalog/cache index is opened.
Future<T> _withProbeControl<T>(
  DownloadResourceCoordinator coordinator,
  Future<T> Function(TaskControl control) run,
) async {
  final completed = Completer<T>();
  final key = 'source-contract:${_events.length}';
  coordinator.networkLane.submit(key: key, priority: 1000, task: (control) async {
    try { completed.complete(await run(control)); }
    on Object catch (error, stack) { completed.completeError(error, stack); }
  });
  try { return await completed.future; }
  finally { await coordinator.networkLane.idleKeys(<String>[key]); }
}

Map<String, Object?> _opaqueModel(String value, String kind) {
  final prefix = 'mihon:$kind:';
  if (!value.startsWith(prefix)) throw StateError('unexpected model kind');
  final decoded = jsonDecode(utf8.decode(base64Url.decode(
    base64Url.normalize(value.substring(prefix.length)),
  ))) as Map<String, dynamic>;
  if (decoded['kind'] != kind) throw StateError('opaque model kind mismatch');
  return Map<String, Object?>.from(decoded);
}

String? _probeHeader(Map<String, String> headers, String name) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
  }
  return null;
}

bool _probeBytesEqual(List<int>? first, List<int>? second) {
  if (first == null || second == null) return first == second;
  if (first.length != second.length) return false;
  for (var i = 0; i < first.length; i++) {
    if (first[i] != second[i]) return false;
  }
  return true;
}

void _assertProbePlanEqual(ComicResourceRequest expected, ComicResourceRequest actual) {
  if (expected.uri != actual.uri || expected.method != actual.method ||
      !_probeBytesEqual(expected.body, actual.body) ||
      expected.headers.length != actual.headers.length) {
    throw StateError('request plan changed across controlled transport');
  }
  for (final entry in expected.headers.entries) {
    if (_probeHeader(actual.headers, entry.key) != entry.value) {
      throw StateError('request header changed across controlled transport');
    }
  }
}

Map<String, Object?> _probePlanSummary(Uri locator, ComicResourceRequest plan) {
  final raw = _opaqueModel(locator.toString(), 'resource');
  final deferred = raw['deferredPage'] == true;
  if (!deferred) {
    final method = (raw['method'] as String? ?? 'GET').trim().toUpperCase();
    final body = raw['bodyBase64'] is String
        ? base64Decode(raw['bodyBase64'] as String) : null;
    if (raw['url'] != plan.uri.toString() || method != plan.method ||
        !_probeBytesEqual(body, plan.body)) {
      throw StateError('serialized source request fields were lost');
    }
    final headers = raw['headers'] as Map<String, dynamic>? ?? const {};
    for (final entry in headers.entries) {
      // The source client may replace Cookie/UA with its current browser
      // snapshot. Exact effective values are checked at transport ingress.
      if (entry.key.toLowerCase() == 'cookie' ||
          entry.key.toLowerCase() == 'user-agent') { continue; }
      if (_probeHeader(plan.headers, entry.key) != entry.value.toString()) {
        throw StateError('serialized source header was lost');
      }
    }
  }
  return <String, Object?>{
    'deferredImageResolution': deferred,
    'serializedRequestCompared': !deferred,
    'method': plan.method,
    'headers': plan.headers.length,
    'hasReferer': _probeHeader(plan.headers, 'Referer') != null,
    'hasCookie': _probeHeader(plan.headers, 'Cookie') != null,
    'hasUserAgent': _probeHeader(plan.headers, 'User-Agent') != null,
    'bodyBytes': plan.body?.length ?? 0,
    'requiresRuntimeTransform': plan.requiresRuntimeTransform,
    'hasChapterReplay': raw['retryChapterId'] is String,
    'hasPageReplay': raw['retryPageIndex'] is int,
  };
}

Future<void> _probeMihonContracts(
  ExternalPluginController controller,
  BrowsableComicSource source,
  DownloadResourceCoordinator coordinator,
) async {
  final id = source.sourceId;
  final owner = controller.ownerOfSource(id);
  final installed = controller.installed.singleWhere((p) => p.plugin.pluginId == owner);
  await _record(<String, Object?>{
    'source': id, 'step': 'contract-descriptor', 'status': 'passed',
    'result': <String, Object?>{
      'name': source.descriptor.name, 'pluginId': owner,
      'version': installed.plugin.version, 'abi': installed.extensionLib,
    },
  });
  final browse = await _step<SourceBrowsePage>(id, 'contract-browse', () async {
    final result = await source.browse();
    if (result.items.isEmpty) throw StateError('no contract sample available');
    return result;
  }, (page) => <String, Object?>{'items': page.items.length});
  if (browse == null) return;
  final summary = browse.items.first;
  final rawManga = _opaqueModel(summary.comicId, 'manga');
  final comic = await _step<ComicManifest>(id, 'contract-catalog-input', () async {
    final result = await source.loadComic(summary.comicId);
    if (result.comic.comicId != summary.comicId || result.chapters.isEmpty) {
      throw StateError('catalog identity changed or nonempty sample was lost');
    }
    return result;
  }, (result) => <String, Object?>{
    'rawInputFields': rawManga.keys.toList()..sort(),
    'rawUrlNonempty': (rawManga['url'] as String? ?? '').isNotEmpty,
    'rawTitleNonempty': (rawManga['title'] as String? ?? '').isNotEmpty,
    'rawMemoPresent': rawManga.containsKey('memo'),
    'inputIdentityPreserved': result.comic.comicId == summary.comicId,
    'detailsTitleNonempty': result.comic.title.isNotEmpty,
    'chapters': result.chapters.length,
  });
  if (comic == null) return;
  await _step<ComicManifest>(id, 'contract-catalog-refresh', () async {
    final result = await source.loadComic(summary.comicId);
    if (result.chapters.isEmpty) throw StateError('refresh lost nonempty catalog');
    if (result.chapters.map((c) => c.chapterId).toSet().length != result.chapters.length) {
      throw StateError('catalog contains duplicate complete identities');
    }
    return result;
  }, (result) => <String, Object?>{
    'beforeChapters': comic.chapters.length, 'afterChapters': result.chapters.length,
    'sameCompleteChapterIds': result.chapters.length == comic.chapters.length &&
        List.generate(result.chapters.length,
          (i) => result.chapters[i].chapterId == comic.chapters[i].chapterId,
        ).every((same) => same),
    'runtimeAdapterWithoutDurableCache': true,
  });
  final selected = comic.chapters.first;
  final rawChapter = _opaqueModel(selected.chapterId, 'chapter');
  final chapter = await _step<ChapterManifest>(id, 'contract-chapter-model', () async {
    final result = await source.loadChapter(selected.chapterId);
    if (result.pages.isEmpty || result.chapter.chapterId != selected.chapterId) {
      throw StateError('chapter failed to preserve identity or resolve pages');
    }
    return result;
  }, (result) => <String, Object?>{
    'rawChapterFields': rawChapter.keys.toList()..sort(),
    'rawMemoPresent': rawChapter.containsKey('memo'),
    'namePreserved': rawChapter['name'] == selected.title,
    'chapterIdentityPreserved': result.chapter.chapterId == selected.chapterId,
    'pages': result.pages.length,
  });
  if (chapter == null) return;
  final direct = RhttpSourceResourceDirectTransport(preparePlatform: prepareRhttpPlatform);
  try {
    final cover = summary.coverUri;
    if (cover != null) {
      await _probeContractMedia(source, cover, direct, coordinator, 'cover');
    }
    final page = chapter.pages.first.uri;
    await _probeContractMedia(source, page, direct, coordinator, 'page');
    await _step<Map<String, Object?>>(id, 'contract-fresh-page', () async {
      final pool = ExternalPluginResourceTransportPool(controlledDirectOpen: direct.open);
      try {
        await _withProbeControl(coordinator,
          (control) => pool.refreshResourceFor(source, page, control: control),
        );
        final resolver = source as ControlledResolvableComicResourceSource;
        final first = await _withProbeControl(coordinator,
          (control) => resolver.resolveResourceControlled(page, control: control),
        );
        final second = await _withProbeControl(coordinator,
          (control) => resolver.resolveResourceControlled(page, control: control),
        );
        _assertProbePlanEqual(first, second);
        final media = await _readMedia(source, page, pool, coordinator);
        return <String, Object?>{
          ...media, 'explicitFreshGenerationCompleted': true,
          'repeatedResolveSameEffectivePlan': true,
        };
      } finally { pool.close(); }
    }, (result) => result);
    // Exercise the stable compatibility branch with this real extension/page;
    // the injected failure is test-only and cannot affect ordinary host traffic.
    if (installed.plugin.pluginId == 'mihon:eu.kanade.tachiyomi.extension.zh.wnacg') {
      final locators = <String, Uri>{'page': page};
      if (cover != null) { locators['cover'] = cover; }
      for (final entry in locators.entries) {
        await _probeContractFallback(source, entry.value, coordinator, entry.key);
      }
    }
  } finally { direct.close(); }
}

Future<void> _probeContractMedia(
  BrowsableComicSource source,
  Uri locator,
  RhttpSourceResourceDirectTransport direct,
  DownloadResourceCoordinator coordinator,
  String kind,
) async {
  final id = source.sourceId;
  final plan = await _step<ComicResourceRequest>(id, 'contract-$kind-plan',
    () => _withProbeControl(coordinator, (control) =>
      (source as ControlledResolvableComicResourceSource)
          .resolveResourceControlled(locator, control: control),
    ), (plan) => _probePlanSummary(locator, plan),
  );
  if (plan == null) return;
  var directCalls = 0;
  final pool = ExternalPluginResourceTransportPool(controlledDirectOpen: (request, {control}) async {
    if (control == null) throw StateError('host transport lost scheduler control');
    _assertProbePlanEqual(normalizeSourceResourceRequest(plan), request);
    directCalls++;
    return direct.open(request, control: control);
  });
  try {
    final step = plan.requiresRuntimeTransform
        ? 'contract-$kind-runtime-media' : 'contract-$kind-host-stream';
    await _step<Map<String, Object?>>(id, step, () async {
      final result = await _readMedia(source, locator, pool, coordinator);
      final diagnostics = result['diagnostics'] as Map<String, Object?>;
      if (!plan.requiresRuntimeTransform &&
          (directCalls != 1 || diagnostics['sourceOpenPath'] != 'direct')) {
        throw StateError('ordinary media did not use direct host streaming');
      }
      return <String, Object?>{
        ...result, 'directCalls': directCalls,
        'controlledEffectivePlanPreserved': directCalls > 0,
      };
    }, (result) => result);
  } finally { pool.close(); }
}

Future<void> _probeContractFallback(
  BrowsableComicSource source,
  Uri locator,
  DownloadResourceCoordinator coordinator,
  String kind,
) async {
  var injected = 0;
  final pool = ExternalPluginResourceTransportPool(controlledDirectOpen: (request, {control}) async {
    if (control == null) throw StateError('compatibility path lost scheduler control');
    control.throwIfCancelled();
    injected++;
    throw const Failure(
      code: ErrorCode.network, message: 'device contract protocol mismatch',
      details: <String, Object?>{
        'sourceMediaProtocolMismatch': true, 'sourceClientStateRequired': true,
      },
    );
  });
  try {
    await _step<Map<String, Object?>>(source.sourceId,
      'contract-$kind-protocol-fallback', () async {
        final result = await _readMedia(source, locator, pool, coordinator);
        final diagnostics = result['diagnostics'] as Map<String, Object?>;
        if (injected != 1 || diagnostics['sourceOpenPath'] != 'client-runtime-fallback') {
          throw StateError('source-client compatibility branch was not exercised');
        }
        return <String, Object?>{...result, 'injectedMismatchCount': injected};
      }, (result) => result,
    );
  } finally { pool.close(); }
}

Future<void> _probeNonMediaRejection(DownloadResourceCoordinator coordinator) async {
  await _step<Map<String, Object?>>('host', 'contract-non-media-2xx', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final served = Completer<void>();
    final listener = server.listen((request) async {
      try {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.html;
        request.response.write('<html><body>contract non-media response</body></html>');
        await request.response.close();
        if (!served.isCompleted) served.complete();
      } on Object catch (error, stack) {
        if (!served.isCompleted) served.completeError(error, stack);
      }
    });
    final direct = RhttpSourceResourceDirectTransport(preparePlatform: prepareRhttpPlatform);
    try {
      final rejected = await _withProbeControl(coordinator, (control) async {
        ByteResponse? response;
        try {
          response = await direct.open(ComicResourceRequest(
            uri: Uri.parse('http://127.0.0.1:${server.port}/non-media'),
          ), control: control);
          throw StateError('non-media 2xx escaped prefix validation');
        } on Failure catch (error) {
          if (error.details['sourceMediaProtocolMismatch'] != true ||
              error.details['sourceMediaSemanticRejected'] != true) { rethrow; }
          return true;
        } finally { await response?.discard(control: control); }
      });
      await served.future;
      return <String, Object?>{
        'statusCode': 200, 'rejectedBeforeDecoder': rejected,
        'productionRhttpPrefixValidation': true,
      };
    } finally {
      direct.close();
      await listener.cancel();
      await server.close(force: true);
    }
  }, (result) => result);
}

Future<void> _probeMihonRestarts(
  ExternalPluginController controller,
  DownloadResourceCoordinator coordinator,
) async {
  final owners = <String>{};
  final sources = List<BrowsableComicSource>.of(controller.activeSources);
  for (final source in sources) {
    if (!source.sourceId.startsWith('mihon:') ||
        (_selectedProbeSource.isNotEmpty && source.sourceId != _selectedProbeSource)) { continue; }
    final owner = controller.ownerOfSource(source.sourceId);
    if (owner == null || !owners.add(owner)) continue;
    await _step<Map<String, Object?>>(source.sourceId, 'contract-runtime-restart', () async {
      final browse = await source.browse();
      if (browse.items.isEmpty) throw StateError('no restart contract sample');
      final originalSources = List<BrowsableComicSource>.of(controller.activeSources);
      await controller.restartMihonSourceForBrowserHandoff(source.sourceId);
      final replacement = controller.activeSources.singleWhere(
        (item) => item.sourceId == source.sourceId,
      );
      if (identical(replacement, source)) throw StateError('runtime was not replaced');
      for (final original in originalSources) {
        if (controller.ownerOfSource(original.sourceId) == owner) continue;
        if (!controller.activeSources.any((item) => identical(original, item))) {
          throw StateError('unrelated source replaced during restart');
        }
      }
      final comic = await replacement.loadComic(browse.items.first.comicId);
      if (comic.chapters.isEmpty) throw StateError('restart lost source catalog');
      final chapter = await replacement.loadChapter(comic.chapters.first.chapterId);
      if (chapter.pages.isEmpty) throw StateError('restart lost source pages');
      final transport = ExternalPluginResourceTransportPool(
        directTransport: RhttpSourceResourceDirectTransport(preparePlatform: prepareRhttpPlatform),
      );
      try {
        final media = await _readMedia(replacement, chapter.pages.first.uri, transport, coordinator);
        return <String, Object?>{
          ...media, 'runtimeReplaced': true, 'unrelatedSourcesPreserved': true,
          'chapters': comic.chapters.length, 'pages': chapter.pages.length,
          'cookieResetOrderingVerified': false,
        };
      } finally { transport.close(); }
    }, (result) => result);
  }
}

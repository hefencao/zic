part of 'source_device_acceptance.dart';

// Two real Settings mutations exercise retained production network objects.
// Only the loopback repository's self-signed TLS is trusted in this test zone.
Future<void> _probeNetworkUserAgent() async {
  final support = (await getStartupApplicationSupportPath())!;
  _results = File('$support/zic-source-user-agent-results.json');
  final snapshot = File('$support/zic_network_browser_snapshot.json');
  final previous = await snapshot.exists() ? await snapshot.readAsBytes() : null;
  final root = await Directory.systemTemp.createTemp('zic-user-agent-');
  final preferences = AppPreferencesController();
  String provider() => preferences.networkUserAgent;
  final general = HttpTransport(userAgentProvider: provider);
  final factory = defaultLocalMediaPipelineFactory.withUserAgentProvider(provider);
  final controller = await ExternalPluginController.openDeferred(root.path,
    userAgentProvider: provider, discoverDeviceMihonExtensions: false,
    deferRuntimeActivation: true);
  final seen = <String, String?>{};
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xff336699), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(32, 32);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  image.dispose();
  picture.dispose();
  final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final tls = SecurityContext()
    ..useCertificateChainBytes(utf8.encode(_userAgentCertificate))
    ..usePrivateKeyBytes(utf8.encode(_userAgentPrivateKey));
  final https = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, tls);
  void serve(HttpServer server, {bool repository = false}) {
    server.listen((request) async {
      seen[request.uri.path] = request.headers.value(HttpHeaders.userAgentHeader);
      if (repository) {
        request.response.write('[]');
      } else if (request.uri.path.startsWith('/web-')) {
        request.response.headers.contentType = ContentType.html;
        request.response.write('<!doctype html><title>UA browser ready</title><p>UA browser ready</p>');
      } else {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(bytes);
      }
      await request.response.close();
    });
  }
  serve(http);
  serve(https, repository: true);
  final base = Uri.parse('http://127.0.0.1:${http.port}');
  var passed = false;
  try {
    for (final plugin in <String>['texture_bridge', 'reader_runtime']) {
      await attachAndroidPlugin(plugin);
    }
    await prewarmDefaultLocalMediaPipeline();
    runApp(MaterialApp(home: NetworkSettingsScreen(preferences: preferences,
      policyBinding: WholeComicPolicySettingsBinding(changes: preferences,
        readSnapshot: () => const WholeComicQueueSnapshot(policy: WholeComicQueuePolicy(),
          environment: WholeComicQueueEnvironment(networkAvailable: true,
            unmetered: true, charging: true), jobs: <WholeComicQueueJobSnapshot>[]),
        updatePolicy: (_) async { throw StateError('policy is outside UA acceptance'); }))));
    for (final phase in <String>['one', 'two']) {
      final expected = phase == 'one' ? '314159265358' : '271828182845';
      await _record(<String, Object?>{'source': 'network', 'step': 'awaiting-$phase',
        'status': 'ready', 'expected_test_UA': expected, 'real_NetworkSettingsScreen': true});
      final changed = Completer<void>();
      void observe() { if (provider() == expected && !changed.isCompleted) changed.complete(); }
      preferences.addListener(observe);
      try {
        await changed.future.timeout(const Duration(minutes: 3));
      } finally {
        preferences.removeListener(observe);
      }
      final response = await general.open(base.replace(path: '/general-$phase'));
      await response.bytes.drain<void>();
      final chapter = ChapterManifest(sourceId: 'ua-fixture', comicId: phase,
        chapter: Chapter(chapterId: phase, comicId: phase, title: phase,
          sequence: 1, pageCount: 1, sourceRevision: phase),
        pages: <PageAsset>[PageAsset(pageId: 'page', chapterId: phase, index: 0,
          uri: base.replace(path: '/reader-$phase'), contentKindHint: ContentKindHint.png)],
        readingDirection: ReadingDirection.ltr);
      final session = factory.create(chapter: chapter, sessionId: 'ua-$phase');
      try {
        session.attach(DecodeTarget(physicalWidth: 32, physicalHeight: 32,
          renderer: session.renderer));
        session.accept(ReaderObs(sessionId: 'ua-$phase', currentIndex: 0, stableIndex: 0,
          interaction: Interaction.idle, logicalPosition: 0, velocity: 0,
          currentCoverage: Coverage(pageIndex: 0, assetKey: chapter.pages.single.assetKey, fraction: 1),
          direction: ReadingDirection.ltr, timestamp: DateTime.now(), monotonicMicros: 1));
        final watch = Stopwatch()..start();
        while (!seen.containsKey('/reader-$phase') && watch.elapsed < const Duration(seconds: 20)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        if (seen['/reader-$phase'] != expected) throw StateError('Reader fallback UA missing');
      } finally {
        await session.dispose();
      }
      await factory.disposeTransferRuntimes();
      await HttpOverrides.runWithHttpOverrides(() => controller.loadRepository(
          format: ExternalComicPluginFormat.veneraJavaScript,
          index: Uri.parse('https://127.0.0.1:${https.port}/repo-$phase.json')),
        _UserAgentRepositoryOverrides(https.port));
      for (final explicit in <bool>[false, true]) {
        final path = '/web-$phase-${explicit ? "explicit" : "default"}';
        await _record(<String, Object?>{'source': 'network', 'step': 'awaiting-browser',
          'status': 'ready', 'phase': phase, 'explicit_source_UA': explicit});
        await const AndroidNetworkBridge().openBrowser(base.replace(path: path),
          userAgent: explicit ? 'SourceOwnedUA/1' : provider());
        if (seen[path] != (explicit ? 'SourceOwnedUA/1' : expected)) {
          throw StateError('actual ordinary WebView UA priority mismatch');
        }
      }
      final matched = <String, bool>{
        'general_HTTP': seen['/general-$phase'] == expected,
        'Reader_fallback': seen['/reader-$phase'] == expected,
        'repository_HTTPS': seen['/repo-$phase.json'] == expected,
        'ordinary_source_WebView': seen['/web-$phase-default'] == expected,
        'source_explicit_UA_precedes_global': seen['/web-$phase-explicit'] == 'SourceOwnedUA/1',
      };
      if (matched.values.any((value) => !value)) throw StateError('network UA assertion failed');
      await _record(<String, Object?>{'source': 'network', 'step': phase,
        'status': 'passed', 'matches': matched, 'retained_provider_and_objects': true});
    }
    passed = true;
  } on Object catch (error) {
    await _record(<String, Object?>{'source': 'network', 'step': 'failure',
      'status': 'failed', 'errorType': error.runtimeType.toString(), 'error': error.toString()});
  } finally {
    general.close(force: true);
    await controller.close();
    await factory.disposeRetainedSessions();
    await factory.disposeTransferRuntimes();
    await shutdownDefaultLocalMediaPipeline();
    await http.close(force: true);
    await https.close(force: true);
    if (previous == null) {
      if (await snapshot.exists()) await snapshot.delete();
    } else {
      await snapshot.writeAsBytes(previous, flush: true);
    }
    final restored = previous == null ? !await snapshot.exists() :
        jsonEncode(await snapshot.readAsBytes()) == jsonEncode(previous);
    await root.delete(recursive: true);
    runApp(MaterialApp(home: Scaffold(body: Center(child: Text(passed && restored ?
      '网络 UA 验收通过' : '网络 UA 验收失败')))));
    await WidgetsBinding.instance.endOfFrame;
    preferences.dispose();
    await _record(<String, Object?>{'source': 'network', 'step': 'complete',
      'status': passed && restored ? 'passed' : 'failed',
      'original_snapshot_restored_exactly': restored, 'user_preferences_store_opened': false,
      'user_library_or_artifact_index_opened': false, 'HTTP_TLS_and_production_owners_closed': true,
      'temporary_directory_removed': !await root.exists()});
  }
}

final class _UserAgentRepositoryOverrides extends HttpOverrides {
  _UserAgentRepositoryOverrides(this.port);
  final int port;
  @override
  HttpClient createHttpClient(SecurityContext? context) => super.createHttpClient(context)
    ..badCertificateCallback = (certificate, host, candidatePort) =>
        host == '127.0.0.1' && candidatePort == port;
}

// Actual Activity/WebView capture lifecycle; the user's single handoff file is
// restored byte-for-byte in finally. No source, library or artifact store opens.
Future<void> _probeBrowserCancellation() async {
  final support = await getStartupApplicationSupportPath();
  if (support == null) throw StateError('browser support path missing');
  final snapshot = File('$support/zic_network_browser_snapshot.json');
  final previous = await snapshot.exists() ? await snapshot.readAsBytes() : null;
  _results = File('$support/zic-source-browser-lifecycle-results.json');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final held = <HttpResponse>[];
  final started = <String, Completer<void>>{
    for (final name in <String>['cancel', 'interrupt']) name: Completer<void>(),
  };
  server.listen((request) async {
    if (request.uri.path == '/ready') {
      request.response.headers.contentType = ContentType.html;
      request.response.write('<!doctype html><title>Snapshot fixture ready</title>'
          '<script>document.cookie="zic_browser_fixture=present; Path=/";'
          'localStorage.setItem("zic_browser_fixture","present");</script>'
          '<p>Browser snapshot ready</p>');
      await request.response.close();
    } else {
      held.add(request.response);
      final signal = started[request.uri.path.substring(1)];
      if (signal != null && !signal.isCompleted) signal.complete();
      // No response headers/document: Back or Activity interruption occurs
      // before any completed page capture is possible.
    }
  });
  const bridge = AndroidNetworkBridge();
  final ready = Uri.parse('http://127.0.0.1:${server.port}/ready');
  var passed = true;
  try {
    await bridge.openBrowser(ready, cloudflareVerification: true);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final baseline = jsonDecode(await snapshot.readAsString()) as Map<String, dynamic>;
    if (baseline['title'] != 'Snapshot fixture ready' ||
        !(baseline['cookieHeader'] as String).contains('zic_browser_fixture=present') ||
        baseline['localStorage'] != '{"zic_browser_fixture":"present"}' ||
        (baseline['userAgent'] as String).isEmpty ||
        (baseline['updatedAt'] as num) <= 0) {
      throw StateError('real completed WebView capture missing');
    }
    await _record(<String, Object?>{'source': 'browser', 'step': 'completed-capture',
      'status': 'passed', 'actual_WebView_cookie_storage_and_provider_UA': true});
    for (final action in <String>['cancel', 'interrupt']) {
      final pending = bridge.openBrowser(ready.replace(path: '/$action'),
          cloudflareVerification: true).then<Object?>((_) => null,
          onError: (Object error) => error);
      await started[action]!.future.timeout(const Duration(seconds: 20));
      final atBegin = jsonDecode(await snapshot.readAsString()) as Map<String, dynamic>;
      const fields = <String>['currentUrl', 'title', 'cookieHeader', 'localStorage',
        'userAgent', 'updatedAt'];
      await _record(<String, Object?>{'source': 'browser', 'step': 'awaiting-$action',
        'status': 'ready', 'response_document_finished': false,
        'changed_fields_before_action': fields.where((key) => atBegin[key] != baseline[key]).toList()});
      final result = await pending.timeout(const Duration(seconds: 30));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final after = jsonDecode(await snapshot.readAsString()) as Map<String, dynamic>;
      final changed = fields.where((key) => after[key] != baseline[key]).toList();
      final unchanged = changed.isEmpty;
      passed = passed && unchanged && result != null;
      await _record(<String, Object?>{'source': 'browser', 'step': action,
        'status': unchanged && result != null ? 'passed' : 'failed',
        'snapshot_fields_and_revision_unchanged': unchanged,
        'changed_fields_after_action': changed,
        'revision_delta_millis': (after['updatedAt'] as num) - (baseline['updatedAt'] as num),
        'revision_advanced': after['updatedAt'] != baseline['updatedAt'],
        'browser_completed_successfully': result == null});
      // Keep the two cancellation inputs independent even on the old defect.
      await snapshot.writeAsString(jsonEncode(baseline), flush: true);
    }
  } on Object catch (error) {
    passed = false;
    await _record(<String, Object?>{'source': 'browser', 'step': 'failure',
      'status': 'failed', 'errorType': error.runtimeType.toString()});
  } finally {
    for (final response in held) {
      await response.close().catchError((Object _) {});
    }
    await server.close(force: true);
    if (previous != null) {
      await snapshot.writeAsBytes(previous, flush: true);
    } else if (await snapshot.exists()) {
      await snapshot.delete();
    }
    final restored = previous == null ? !await snapshot.exists() :
        jsonEncode(await snapshot.readAsBytes()) == jsonEncode(previous);
    await _record(<String, Object?>{'source': 'browser', 'step': 'complete',
      'status': passed && restored ? 'passed' : 'failed',
      'original_snapshot_restored_exactly': restored,
      'user_library_or_artifact_index_opened': false,
      'source_runtime_activated': false, 'HTTP_server_and_responses_closed': true});
  }
}

Future<void> _probeFilterOverrides(
  FilterableBrowsableComicSource source,
  String sourceId,
  List<SourceSearchFilterNode> filters,
) async {
  final nodes = <SourceSearchFilterNode>[];
  void visit(SourceSearchFilterNode node) {
    nodes.add(node);
    for (final child in node.children) { visit(child); }
  }
  for (final node in filters) { visit(node); }
  for (final kind in <SourceSearchFilterKind>[
    SourceSearchFilterKind.checkBox,
    SourceSearchFilterKind.triState,
    SourceSearchFilterKind.select,
  ]) {
    final matches = nodes.where((node) => node.kind == kind).toList();
    await _step<Map<String, Object?>>(
      sourceId, 'filter-override-${kind.name}', () async {
        if (matches.isEmpty) throw StateError('required real filter kind missing');
        final node = matches.first;
        if (node.label.trim().isEmpty) throw StateError('filter label missing');
        final Object value = switch (kind) {
          SourceSearchFilterKind.checkBox => !(node.value as bool),
          SourceSearchFilterKind.triState => node.value == 1 ? 2 : 1,
          SourceSearchFilterKind.select =>
              ((node.value as int) + 1) % node.options.length,
          _ => throw StateError('unexpected acceptance filter kind'),
        };
        final page = await source.browseWithFilters(
          filterState: <String, Object?>{node.filterId: value},
        );
        return <String, Object?>{
          'filterId': node.filterId,
          'label': node.label,
          'default': node.value,
          'override': value,
          'items': page.items.length,
          'insideGroup': filters.any((parent) =>
              parent.children.any((child) => child.filterId == node.filterId)),
        };
      }, (result) => result,
    );
  }
}

Future<void> _probeCompleteCollection(
  BrowsableComicSource source,
  SourceBrowsePage first,
) async {
  await _step<Map<String, Object?>>(
    source.descriptor.sourceId, 'complete-collection-exhaustion', () async {
      var page = first;
      final sizes = <int>[];
      while (true) {
        sizes.add(page.items.length);
        if (!page.hasMore) break;
        if (sizes.length >= 32) {
          throw StateError('fixture collection did not terminate in 32 pages');
        }
        page = await source.browse(offset: sizes.length * 24);
      }
      final beyond = await source.browse(offset: sizes.length * 24);
      if (beyond.items.isNotEmpty || beyond.hasMore) {
        throw StateError('exhausted collection remains pageable');
      }
      return <String, Object?>{
        'pages': sizes.length,
        'pageSizes': sizes,
        'items': sizes.fold<int>(0, (sum, n) => sum + n),
        'beyondEmpty': true,
      };
    }, (result) => result,
  );
}

Future<void> _probeSettingsInPlace(
  ExternalPluginController controller,
  BrowsableComicSource source,
) async {
  if (source is! ConfigurableComicSource) return;
  final configurable = source as ConfigurableComicSource;
  await _step<Map<String, Object?>>(
    source.descriptor.sourceId, 'settings-in-place', () async {
      final settings = await configurable.loadSettings();
      final toggles = settings.where((setting) => !setting.sensitive &&
          setting.kind == ComicSourceSettingKind.toggle &&
          setting.value is bool).toList();
      if (toggles.isEmpty) {
        throw StateError('fixture source has no safe toggle to exercise');
      }
      final setting = toggles.first;
      try {
        for (final value in <bool>[!(setting.value as bool), setting.value as bool]) {
          await configurable.updateSetting(setting.key, value);
          final current = (await configurable.loadSettings())
              .firstWhere((item) => item.key == setting.key);
          if (current.value != value || !identical(source,
              controller.activeSources.firstWhere(
                (item) => item.descriptor.sourceId == source.descriptor.sourceId,
              ))) {
            throw StateError('setting mutation changed source or lost value');
          }
        }
        return <String, Object?>{
          'settings': settings.length,
          'mutations': 2,
          'originalSourcePreserved': true,
        };
      } finally {
        await configurable.updateSetting(setting.key, setting.value);
      }
    }, (result) => result,
  );
}

Future<void> _probeRejectedReplacement(ExternalPluginController controller) async {
  final record = controller.installed.firstWhere(
    (item) => item.plugin.format == ExternalComicPluginFormat.veneraJavaScript,
  );
  final originals = controller.activeSources.where(
    (source) => controller.ownerOfSource(source.descriptor.sourceId) ==
        record.plugin.pluginId,
  ).toList();
  await _step<Map<String, Object?>>(
    'registry', 'rejected-replacement-preserves-active', () async {
      if (originals.isEmpty) throw StateError('no original active source');
      final payload = File(record.payloadPath);
      final bytes = await payload.readAsBytes();
      var rejected = false;
      try {
        await payload.writeAsBytes(<int>[...bytes, 0], flush: true);
        try { await controller.retryActivation(record.plugin.pluginId); }
        on Object { rejected = true; }
      } finally { await payload.writeAsBytes(bytes, flush: true); }
      if (!rejected) throw StateError('modified payload passed verification');
      for (final source in originals) {
        if (!identical(source, controller.activeSources.firstWhere(
          (item) => item.descriptor.sourceId == source.descriptor.sourceId,
        ))) { throw StateError('rejected candidate replaced active source'); }
      }
      final page = await originals.first.browse();
      if (page.items.isEmpty) throw StateError('old active source is unreadable');
      return <String, Object?>{
        'candidateRejected': true,
        'originalSourcesPreserved': originals.length,
        'oldSourceBrowseItems': page.items.length,
      };
    }, (result) => result,
  );
}

Future<void> _probeManifestRecovery(
  Directory probeRoot,
  Map<String, dynamic> originalManifest,
) async {
  for (final kind in <String>['invalid', 'part', 'bak', 'bad-record', 'hash-pin']) {
    await _step<Map<String, Object?>>('manifest', kind, () async {
      final root = Directory('${probeRoot.path}/manifest-$kind-'
          '${DateTime.now().microsecondsSinceEpoch}');
      final payloadRoot = Directory('${root.path}/external_plugins');
      await payloadRoot.create(recursive: true);
      final manifest = jsonDecode(jsonEncode(originalManifest))
          as Map<String, dynamic>;
      final records = manifest['plugins'] as List;
      for (final value in records) {
        final record = value as Map<String, dynamic>;
        final payload = File(record['payloadPath'] as String);
        final copied = await payload.copy(
          '${payloadRoot.path}/${payload.uri.pathSegments.last}',
        );
        record['payloadPath'] = copied.path;
      }
      final expected = records.length;
      String? corruptedPlugin;
      if (kind == 'bad-record') {
        records.add(<String, Object?>{'plugin': null});
      } else if (kind == 'hash-pin') {
        final record = records.first as Map<String, dynamic>;
        corruptedPlugin = (record['plugin'] as Map)['pluginId'] as String;
        await File(record['payloadPath'] as String)
            .writeAsBytes(<int>[0], mode: FileMode.append, flush: true);
      }
      final suffix = <String>{'invalid', 'part', 'bak'}.contains(kind)
          ? '.$kind' : '';
      if (kind == 'bak') {
        await File('${payloadRoot.path}/installed.json')
            .writeAsString('{broken', flush: true);
      }
      await File('${payloadRoot.path}/installed.json$suffix')
          .writeAsString(jsonEncode(manifest), flush: true);
      final controller = await ExternalPluginController.openDeferred(
        root.path,
        discoverDeviceMihonExtensions: false,
        deferRuntimeActivation: true,
      );
      try {
        await controller.ready;
        final expectedActive = expected - (corruptedPlugin == null ? 0 : 1);
        if (controller.installed.length != expected ||
            _activePluginCount(controller) != expectedActive) {
          throw StateError('recovery lost valid installed or active plugins: '
              'installed=${controller.installed.length}/$expected, '
              'active=${_activePluginCount(controller)}/$expectedActive; '
              'failures=${controller.activationFailures.entries.map(
                (entry) => '${entry.key}: '
                    '${_failureDiagnostics(entry.value)['sanitizedMessage']}',
              ).join('; ')}');
        }
        if (kind == 'bad-record' && controller.manifestRestoreFailures.isEmpty) {
          throw StateError('bad record has no diagnostic');
        }
        if (corruptedPlugin != null &&
            !controller.activationFailures.containsKey(corruptedPlugin)) {
          throw StateError('payload hash failure was not diagnosed');
        }
        if (!await File('${payloadRoot.path}/installed.json').exists()) {
          throw StateError('recovered canonical manifest not published');
        }
        return <String, Object?>{
          'installed': controller.installed.length,
          'activePlugins': _activePluginCount(controller),
          'activeSources': controller.activeSources.length,
          'manifestDiagnostics': controller.manifestRestoreFailures.length,
          'activationFailures': controller.activationFailures.length,
          'corruptPayloadRejected': corruptedPlugin != null,
        };
      } finally { await controller.close(); }
    }, (result) => result);
  }
}

// Public test-only loopback identity; never used by production transport.
const _userAgentCertificate = r'''-----BEGIN CERTIFICATE-----
MIIBmjCCAUGgAwIBAgIUVNDdzclCBmMxHT6LOibTmr0+c/QwCgYIKoZIzj0EAwIw
IjEgMB4GA1UEAwwXemljLWxvb3BiYWNrLWFjY2VwdGFuY2UwIBcNMjYxMDA4MTYw
NzIwWhgPMjEyNjA5MTQxNjA3MjBaMCIxIDAeBgNVBAMMF3ppYy1sb29wYmFjay1h
Y2NlcHRhbmNlMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAESm7x6YbTmQInENn+
7JJCqR2yrpIqe4DNsIJ6AeYQjV08ZPpyrrwqhqlapcRjF/UH01YsaI98cY4ooKRi
Is1z3qNTMFEwHQYDVR0OBBYEFFfk64V8jmd5aCTmWBNKDUfZ0TJ5MB8GA1UdIwQY
MBaAFFfk64V8jmd5aCTmWBNKDUfZ0TJ5MA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZI
zj0EAwIDRwAwRAIgeBOeHDtatqClRT+00FTGYJ2kDzjO/H55tsVMuklUK8cCIDII
U26U5IdZmW8LgVc3T3T40UAWlnugsDa/Z1oi8xNf
-----END CERTIFICATE-----
''';
const _userAgentPrivateKey = r'''-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQglJHckrCh0HULCycw
pvKDN55+AbdPDCSi7yRVucvsSUuhRANCAARKbvHphtOZAicQ2f7skkKpHbKukip7
gM2wgnoB5hCNXTxk+nKuvCqGqVqlxGMX9QfTVixoj3xxjiigpGIizXPe
-----END PRIVATE KEY-----
''';

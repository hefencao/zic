part of 'source_device_acceptance.dart';

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

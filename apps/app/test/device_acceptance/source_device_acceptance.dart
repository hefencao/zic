import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:downloads_bridge/downloads_bridge.dart';
import 'package:flutter/material.dart';
import 'package:network_bridge/network_bridge.dart';
import 'package:pipeline/pipeline.dart';
import 'package:plugin_host/plugin_host.dart';
import 'package:plugin_host_bridge/plugin_host_bridge.dart';
import 'package:storage_bridge/storage_bridge.dart';
import 'package:transport/transport.dart';

import 'package:zic/debug_trace_export.dart';
import 'package:zic/app_preferences.dart';
import 'package:zic/app_settings_screen.dart';
import 'package:zic/local_media_composition.dart';
import 'package:zic/app_runtime.dart' as app_runtime;
import 'package:zic/main.dart' as app_entrypoint;
import 'package:zic/startup_platform.dart';

part 'source_device_governance.dart';
part 'source_device_runtime_capacity.dart';
part 'source_device_contracts.dart';

// Explicit device-test entry point. It copies installed payloads into a separate
// controller root and never opens the user's library or download artifact index.
// Build from apps/app with --target test/device_acceptance/source_device_acceptance.dart.
final _status = ValueNotifier<String>('准备来源验收');
final _events = <Map<String, Object?>>[];
late File _results;
const _selectedProbeSource = String.fromEnvironment('ZIC_SOURCE_ACCEPTANCE_SOURCE');
const _manifestOnly = bool.fromEnvironment('ZIC_SOURCE_ACCEPTANCE_MANIFEST_ONLY');
const _extraMihonPlugin = String.fromEnvironment('ZIC_SOURCE_ACCEPTANCE_MIHON_PLUGIN');
const _filterUi = bool.fromEnvironment('ZIC_SOURCE_ACCEPTANCE_FILTER_UI');
const _contractsOnly = bool.fromEnvironment('ZIC_SOURCE_ACCEPTANCE_CONTRACTS_ONLY');
const _exportProbePayload = String.fromEnvironment('ZIC_SOURCE_ACCEPTANCE_EXPORT_PAYLOAD');
const _metadataOnly = bool.fromEnvironment('ZIC_SOURCE_ACCEPTANCE_METADATA_ONLY');
const _browserOnly = bool.fromEnvironment('ZIC_SOURCE_ACCEPTANCE_BROWSER_ONLY');
const _userAgentOnly = bool.fromEnvironment('ZIC_SOURCE_ACCEPTANCE_USER_AGENT_ONLY');

@pragma('vm:entry-point')
Future<void> zicExternalPluginRuntimeServiceMain() =>
    app_entrypoint.zicExternalPluginRuntimeServiceMain();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('来源设备验收')),
      body: ValueListenableBuilder<String>(
        valueListenable: _status,
        builder: (_, status, _) => Center(child: Text(status)),
      ),
    ),
  ));
  await waitForFirstFlutterUiDisplayed();
  await attachAndroidPlugin('network_bridge');
  if (_userAgentOnly) {
    await _probeNetworkUserAgent();
    return;
  }
  if (_browserOnly) {
    await _probeBrowserCancellation();
    return;
  }
  await attachAndroidPlugin('plugin_host_bridge');
  if (_metadataOnly) {
    await _probeMetadataFailure();
    return;
  }
  await _run();
}

Future<void> _probeMetadataFailure() async {
  final userRoot = await getDefaultZicStorageRoot(
    applicationSupportPath: getStartupApplicationSupportPath,
  );
  final probeRoot = Directory('$userRoot/source-acceptance-2026-10-01');
  await probeRoot.create(recursive: true);
  _results = File('${probeRoot.path}/results.json');
  final scan = await const AndroidMihonApkMetadataReader().scanInstalled(
    knownPackageNames: const <String>['dev.zic.zic'],
  );
  final failure = scan.failures.singleWhere((f) => f.packageName == 'dev.zic.zic');
  await _record(<String, Object?>{
    'source': failure.packageName, 'step': 'metadata-failure-observation',
    'status': 'passed', 'result': <String, Object?>{
      'stage': failure.stage, 'errorType': failure.errorType, 'message': failure.message,
    },
  });
  final passed = await _step<bool>('registry', 'metadata-failure-context', () async {
    if (failure.stage != 'candidate' || scan.extensions.any((e) => e.packageName == 'dev.zic.zic') ||
        !<String>['package=dev.zic.zic', 'metadataKeys=', 'declaredExtensionLib=',
          'extensionLib=', 'entryClasses='].every(failure.message.contains)) {
      throw StateError('Rejected APK lost package/metadata/ABI/entry diagnostics');
    }
    return true;
  }, (_) => <String, Object?>{'public_metadata_only': true, 'unrecognized_APK_rejected': true});
  await _record(<String, Object?>{
    'source': 'registry', 'step': 'complete', 'status': passed == true ? 'passed' : 'failed',
    'user_library_or_artifact_index_opened': false, 'source_runtime_activated': false,
  });
}

Future<void> _record(Map<String, Object?> event) async {
  _events.add(<String, Object?>{
    'at': DateTime.now().toUtc().toIso8601String(),
    ...event,
  });
  _status.value = '${event['source'] ?? ''} ${event['step']}: '
      '${event['status']} (${_events.length})';
  await _results.writeAsString(jsonEncode(_events), flush: true);
}

Future<T?> _step<T>(
  String source,
  String step,
  Future<T> Function() run,
  Object? Function(T value) summarize,
) async {
  final watch = Stopwatch()..start();
  _status.value = '$source $step';
  try {
    final value = await run();
    await _record(<String, Object?>{
      'source': source,
      'step': step,
      'status': 'passed',
      'micros': watch.elapsedMicroseconds,
      'result': summarize(value),
    });
    return value;
  } on Object catch (error) {
    // Headers, cookies, raw manga locators and account state never enter output.
    await _record(<String, Object?>{
      'source': source,
      'step': step,
      'status': 'failed',
      'micros': watch.elapsedMicroseconds,
      'errorType': error.runtimeType.toString(),
      'errorCode': error is Failure ? error.code.name : null,
      'message': error is Failure ? error.code.name : 'device probe failed',
      'diagnostics': _failureDiagnostics(error),
    });
    return null;
  }
}

Map<String, Object?> _failureDiagnostics(Object error) {
  final text = error is Failure
      ? '${error.message}\n${error.cause ?? ''}' : error.toString();
  final statuses = RegExp(r'\b(?:HTTP|status(?:Code)?)[ :=]*(\d{3})\b',
      caseSensitive: false).allMatches(text);
  return <String, Object?>{
    'sanitizedMessage': text
        .replaceAll(RegExp(r'https?://[^\s<]+'), '[url]')
        .replaceAllMapped(RegExp(
          r'(cookie|authorization|password|passwd|token|secret)(\s*[:=]\s*)[^\s<]+',
          caseSensitive: false,
        ), (match) => '${match.group(1)}=[redacted]')
        .replaceAll(RegExp("\"[^\"]*\"|'[^']*'"), '[quoted]')
        .replaceAll(RegExp(r'[A-Za-z0-9+_/=-]{40,}'), '[opaque]')
        .split('\n').first,
    'exceptionKinds': RegExp(r'\b[A-Za-z][A-Za-z0-9_.]*(?:Exception|Error)\b')
        .allMatches(text).map((m) => m.group(0)).toSet().toList(),
    'httpStatuses': statuses.map((m) => int.parse(m.group(1)!))
        .toSet().toList(),
    'signals': <String>[
      for (final signal in <String, String>{
        'login': r'login|log in|登录',
        'authentication': r'authenti|unauthorized',
        'refreshToken': r'refresh.?token',
        'missingToken': r'token.{0,30}(empty|missing|null)|no.{0,20}token',
        'ssl': r'SSL|certificate|handshake',
        'timeout': r'timeout|timed out',
        'dns': r'UnknownHost|resolve host',
        'cloudflare': r'Cloudflare|challenge',
      }.entries)
        if (RegExp(signal.value, caseSensitive: false).hasMatch(text))
          signal.key,
    ],
    if (error is Failure) 'details': <String, Object?>{
      for (final entry in error.details.entries)
        if (entry.value is num || entry.value is bool) entry.key: entry.value,
    },
  };
}

Future<void> _run() async {
  final userRoot = await getDefaultZicStorageRoot(
    applicationSupportPath: getStartupApplicationSupportPath,
  );
  final probeRoot = Directory('$userRoot/source-acceptance-2026-10-01');
  final payloadRoot = Directory('${probeRoot.path}/external_plugins');
  await payloadRoot.create(recursive: true);
  _results = File('${probeRoot.path}/results.json');
  final manifest = jsonDecode(
    await File('$userRoot/external_plugins/installed.json').readAsString(),
  ) as Map<String, dynamic>;
  for (final value in manifest['plugins'] as List) {
    final record = value as Map<String, dynamic>;
    final original = File(record['payloadPath'] as String);
    final filename = original.uri.pathSegments.last;
    final copied = await original.copy('${payloadRoot.path}/$filename');
    record['payloadPath'] = copied.path;
  }
  await File('${payloadRoot.path}/installed.json')
      .writeAsString(jsonEncode(manifest), flush: true);

  final controller = await ExternalPluginController.openDeferred(
    probeRoot.path,
    discoverDeviceMihonExtensions: false,
    deferRuntimeActivation: true,
  );
  final coordinator = DownloadResourceCoordinator();
  final transport = ExternalPluginResourceTransportPool(
    directTransport: RhttpSourceResourceDirectTransport(
      preparePlatform: prepareRhttpPlatform,
    ),
  );
  try {
    final activated = await _step<bool>('registry', 'activate-existing', () async {
      await controller.ready;
      if (controller.activationFailures.isNotEmpty) {
        throw StateError('activation failures: '
            '${controller.activationFailures.entries.map(
              (entry) => '${entry.key}: '
                  '${_failureDiagnostics(entry.value)['sanitizedMessage']}',
            ).join('; ')}');
      }
      if (controller.activeSources.isEmpty) {
        throw StateError('no original source activated');
      }
      return true;
    }, (_) => <String, Object?>{
      'installed': controller.installed.length,
      'activeSources': controller.activeSources.length,
      'abis': controller.installed.map((p) => p.extensionLib).toSet().toList(),
    });

    if (_exportProbePayload.isNotEmpty) {
      final record = controller.installed.singleWhere(
        (item) => item.plugin.pluginId == _exportProbePayload,
      );
      await _step<bool>('registry', 'export-immutable-probe-payload', () async {
        await exportDebugTraceFile(
          suggestedName: 'zic-source-contract-${record.packageName}.apk',
          bytes: await File(record.payloadPath).readAsBytes(),
          relativeDirectory: 'Debug',
        );
        return true;
      }, (_) => <String, Object?>{
        'pluginId': record.plugin.pluginId,
        'version': record.plugin.version, 'sha256': record.payloadSha256,
        'isolatedImmutablePayloadOnly': true,
      });
    }
    if (_manifestOnly) return;
    if (_extraMihonPlugin.isNotEmpty) {
      final repository = Uri.parse(defaultMihonExtensionRepository);
      await _step<bool>('registry', 'install-extra-mihon', () async {
        final candidates = await controller.loadRepository(
          format: ExternalComicPluginFormat.mihonExtension,
          index: repository,
        );
        final candidate = candidates.singleWhere(
          (item) => item.pluginId == _extraMihonPlugin,
        );
        final preview = await controller.inspect(
          plugin: candidate, repository: repository,
        );
        final active = await controller.approveAndActivate(preview);
        if (active.isEmpty) throw StateError('extra Mihon source did not activate');
        return true;
      }, (_) => <String, Object?>{'pluginId': _extraMihonPlugin});
    }
    final originals = List<BrowsableComicSource>.of(controller.activeSources);
    if (_selectedProbeSource.isNotEmpty && !originals.any(
        (source) => source.descriptor.sourceId == _selectedProbeSource)) {
      throw StateError('selected acceptance source is not active');
    }
    for (final source in originals) {
      if (_selectedProbeSource.isNotEmpty &&
          source.descriptor.sourceId != _selectedProbeSource) { continue; }
      if (_contractsOnly) {
        if (source.sourceId.startsWith('mihon:')) {
          await _probeMihonContracts(controller, source, coordinator);
        }
        continue;
      }
      await _probeSource(source, transport, coordinator);
      if (source.descriptor.sourceId.startsWith('venera:')) {
        await _probeSettingsInPlace(controller, source);
      }
    }
    if (_contractsOnly) {
      await _probeMihonRestarts(controller, coordinator);
      await _probeNonMediaRejection(coordinator);
      return;
    }
    if (_filterUi) {
      if (_selectedProbeSource.isEmpty) {
        throw StateError('interactive filter acceptance requires one source');
      }
      await _record(<String, Object?>{
        'source': _selectedProbeSource,
        'step': 'filter-ui-ready', 'status': 'passed',
      });
      runApp(app_runtime.createApp(
        libraryStore: MemoryImportedLibraryStore(),
        comicSources: originals.where(
          (source) => source.descriptor.sourceId == _selectedProbeSource,
        ).toList(),
        persistHomeProjectionSnapshot: false,
        persistMissingPreferences: false,
        storageRoot: '${probeRoot.path}/filter-ui',
      ));
      // Keep the fixture controller alive for explicit ADB interactions. APK
      // restoration ends this test process; no user library/settings are open.
      await Completer<void>().future;
    }
    if (_selectedProbeSource.isNotEmpty) return;
    if (activated == true) {
      await _probeRejectedReplacement(controller);
    }

    final repository = Uri.parse(defaultVeneraSourceRepository);
    final candidates = await _step<List<ExternalComicPluginCatalogEntry>>(
      'registry', 'repository',
      () => controller.loadRepository(
        format: ExternalComicPluginFormat.veneraJavaScript, index: repository,
      ),
      (items) => <String, Object?>{'entries': items.length},
    );
    if (candidates != null) {
      var attempts = 0;
      for (final candidate in candidates) {
        if (_activePluginCount(controller) >= 9 || attempts >= 6) break;
        if (controller.installed.any(
          (item) => item.plugin.pluginId == candidate.pluginId,
        )) { continue; }
        attempts++;
        await _step<bool>('registry', 'install-${candidate.pluginId}', () async {
          final preview = await controller.inspect(
            plugin: candidate, repository: repository,
          );
          final active = await controller.approveAndActivate(preview);
          if (active.isEmpty) throw StateError('no activated source');
          return true;
        }, (_) => <String, Object?>{
          'installed': controller.installed.length,
          'activeSources': controller.activeSources.length,
        });
      }
      await _step<bool>('registry', 'mixed-more-than-eight', () async {
        if (activated != true || originals.isEmpty ||
            _activePluginCount(controller) < 9) {
          throw StateError('original activation or nine active plugins missing');
        }
        for (final source in originals) {
          if (!identical(
            controller.activeSources.firstWhere(
              (s) => s.descriptor.sourceId == source.descriptor.sourceId,
            ), source,
          )) { throw StateError('original source was replaced'); }
        }
        return true;
      }, (_) => <String, Object?>{
        'installed': controller.installed.length,
        'activeSources': controller.activeSources.length,
        'activePlugins': _activePluginCount(controller),
        'originalSourcesPreserved': originals.length,
      });
    }
  } finally {
    coordinator.networkLane.cancelAll();
    await coordinator.networkLane.idle();
    transport.close();
    await controller.close();
    if (_selectedProbeSource.isEmpty && !_contractsOnly) {
      await _probeManifestRecovery(probeRoot, manifest);
      if (!_manifestOnly) await _probeRuntimeCapacity(probeRoot);
    }
    await _record(<String, Object?>{
      'step': 'complete', 'status': 'finished',
      'selectedSource': _selectedProbeSource,
      'failed': _events.where((e) => e['status'] == 'failed').length,
    });
    await exportDebugTraceFile(
      suggestedName: 'zic-source-acceptance-${DateTime.now().millisecondsSinceEpoch}.json',
      bytes: Uint8List.fromList(utf8.encode(jsonEncode(_events))),
      relativeDirectory: 'Debug',
    );
  }
}

int _activePluginCount(ExternalPluginController controller) =>
    controller.activeSources.map(
      (source) => controller.ownerOfSource(source.descriptor.sourceId),
    ).whereType<String>().toSet().length;

Future<void> _probeSource(
  BrowsableComicSource source,
  ExternalPluginResourceTransportPool transport,
  DownloadResourceCoordinator coordinator,
) async {
  final id = source.descriptor.sourceId;
  List<SourceBrowseSection>? sections;
  if (source is SectionedBrowsableComicSource) {
    final sectioned = source as SectionedBrowsableComicSource;
    sections = await _step<List<SourceBrowseSection>>(
      id, 'sections', sectioned.loadBrowseSections,
      (items) => items.map((s) => s.sectionId).toList(),
    );
  }
  if (source is FilterableBrowsableComicSource) {
    final filtered = source as FilterableBrowsableComicSource;
    final filters = await _step<List<SourceSearchFilterNode>>(
      id, 'filter-schema', filtered.loadSearchFilters,
      (items) {
        final kinds = <String, int>{};
        void visit(SourceSearchFilterNode node) {
          kinds.update(node.kind.name, (n) => n + 1, ifAbsent: () => 1);
          for (final child in node.children) { visit(child); }
        }
        for (final node in items) { visit(node); }
        return kinds;
      },
    );
    if (filters != null && filters.isNotEmpty) {
      await _step<SourceBrowsePage>(
        id, 'filter-defaults', () => filtered.browseWithFilters(),
        (page) => <String, Object?>{'items': page.items.length},
      );
      if (_extraMihonPlugin.isNotEmpty) {
        await _probeFilterOverrides(filtered, id, filters);
      }
    }
  }
  final first = await _step<SourceBrowsePage>(
    id, 'browse', source.browse,
    (page) => <String, Object?>{
      'items': page.items.length, 'offset': page.offset, 'hasMore': page.hasMore,
    },
  );
  if (first == null || first.items.isEmpty) return;
  if (id == 'venera:jm') await _probeCompleteCollection(source, first);
  if (first.hasMore) {
    await _step<SourceBrowsePage>(
      id, 'browse-second-page', () async {
        final page = await source.browse(offset: 24);
        if (page.items.isNotEmpty && page.items.length == first.items.length &&
            List.generate(page.items.length,
              (i) => page.items[i].comicId == first.items[i].comicId,
            ).every((same) => same)) {
          throw StateError('second page exactly repeats first page');
        }
        return page;
      },
      (page) => <String, Object?>{
        'items': page.items.length, 'offset': page.offset,
        'hasMore': page.hasMore,
        'overlap': page.items.where(
          (item) => first.items.any((old) => old.comicId == item.comicId),
        ).length,
      },
    );
  }
  if (source is SectionedBrowsableComicSource && sections != null) {
    final sectioned = source as SectionedBrowsableComicSource;
    for (final section in sections) {
      await _step<SourceBrowsePage>(
        id, 'section-${section.sectionId}',
        () => sectioned.browseSection(section.sectionId),
        (page) => <String, Object?>{'items': page.items.length},
      );
    }
  }
  final summary = first.items.first;
  final cover = summary.coverUri;
  if (cover != null) {
    await _step<Map<String, Object?>>(id, 'cover',
      () => _readMedia(source, cover, transport, coordinator), (r) => r);
  }
  final comic = await _step<ComicManifest>(
    id, 'details', () => source.loadComic(summary.comicId),
    (comic) => <String, Object?>{
      'chapters': comic.chapters.length,
      'uniqueChapterIds': comic.chapters.map((c) => c.chapterId).toSet().length,
    },
  );
  if (comic == null || comic.chapters.isEmpty) return;
  final chapter = await _step<ChapterManifest>(
    id, 'chapter', () => source.loadChapter(comic.chapters.first.chapterId),
    (chapter) => <String, Object?>{'pages': chapter.pages.length},
  );
  if (chapter == null || chapter.pages.isEmpty) return;
  await _step<Map<String, Object?>>(id, 'page-body',
    () => _readMedia(source, chapter.pages.first.uri, transport, coordinator),
    (result) => result);
}

Future<Map<String, Object?>> _readMedia(
  BrowsableComicSource source,
  Uri locator,
  ExternalPluginResourceTransportPool transport,
  DownloadResourceCoordinator coordinator,
) async {
  final completed = Completer<Map<String, Object?>>();
  final key = 'source-acceptance:${source.descriptor.sourceId}:${_events.length}';
  coordinator.networkLane.submit(key: key, priority: 1000, task: (control) async {
    ByteResponse? response;
    Map<String, Object?>? result;
    try {
      try {
        response = await transport.controlledLoaderFor(source, locator)(
          control: control,
        );
        final body = BytesBuilder(copy: false);
        await for (final chunk in response.bytes) {
          control.throwIfCancelled();
          body.add(chunk);
          if (body.length > 32 * 1024 * 1024) {
            throw StateError('probe response exceeds 32 MiB');
          }
        }
        final bytes = body.takeBytes();
        final codec = await ui.instantiateImageCodec(bytes);
        try {
          final frame = await codec.getNextFrame();
          try {
            result = <String, Object?>{
              'bytes': bytes.length,
              'width': frame.image.width, 'height': frame.image.height,
              'frames': codec.frameCount,
              'diagnostics': <String, Object?>{
                for (final entry in response.diagnostics.entries)
                  if (entry.value is num || entry.value is bool ||
                      entry.key == 'sourceOpenPath')
                    entry.key: entry.value,
              },
            };
          } finally { frame.image.dispose(); }
        } finally { codec.dispose(); }
      } finally { await response?.discard(control: control); }
      completed.complete(result);
    } on Object catch (error, stack) {
      completed.completeError(error, stack);
    }
  });
  try { return await completed.future; }
  finally { await coordinator.networkLane.idleKeys(<String>[key]); }
}

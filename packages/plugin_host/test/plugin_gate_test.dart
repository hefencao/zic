import 'dart:async';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:plugin_host/plugin_host.dart';
import 'package:test/test.dart';

void main() {
  test('trusted Mihon metadata reaches only the Mihon executor', () async {
    final plugin = _mihonPlugin();
    final inspector = _Inspector(
      ExternalPluginInspection(
        format: ExternalComicPluginFormat.mihonExtension,
        payloadSha256: 'aa',
        packageName: 'eu.kanade.tachiyomi.extension.en.fixture',
        signerSha256: 'bb',
        versionCode: 4,
        extensionLib: 'tachiyomix-v1.6',
        requestedCapabilities: const <ExternalPluginCapability>{
          ExternalPluginCapability.network,
          ExternalPluginCapability.nativeCode,
        },
      ),
    );
    final executor = _Executor(sourceId: 'mihon:42');
    final host = PermissionedExternalComicPluginHost(
      inspector: inspector,
      executor: executor,
      policy: _mihonPolicy(),
    );

    final session = await host.activate(plugin);

    expect(executor.calls, 1);
    expect(session.sources.single.sourceId, 'mihon:42');
    await session.close();
  });

  test('Mihon signer and ABI gates reject before class loading', () async {
    final executor = _Executor(sourceId: 'mihon:42');
    final host = PermissionedExternalComicPluginHost(
      inspector: _Inspector(
        ExternalPluginInspection(
          format: ExternalComicPluginFormat.mihonExtension,
          payloadSha256: 'aa',
          packageName: 'eu.kanade.tachiyomi.extension.en.fixture',
          signerSha256: 'untrusted',
          versionCode: 4,
          extensionLib: 'unknown-abi',
        ),
      ),
      executor: executor,
      policy: _mihonPolicy(),
    );

    await expectLater(
      host.activate(_mihonPlugin()),
      throwsA(
        isA<ExternalPluginActivationException>()
            .having(
              (error) => error.denials,
              'denials',
              contains(ExternalPluginDenial.signerNotTrusted),
            )
            .having(
              (error) => error.denials,
              'denials',
              contains(ExternalPluginDenial.unsupportedAbi),
            ),
      ),
    );
    expect(executor.calls, 0);
  });

  test('Venera capabilities are denied before script evaluation', () async {
    final plugin = _veneraPlugin();
    final executor = _Executor(sourceId: 'venera:fixture');
    final host = PermissionedExternalComicPluginHost(
      inspector: _Inspector(
        ExternalPluginInspection(
          format: ExternalComicPluginFormat.veneraJavaScript,
          payloadSha256: 'cc',
          sourceKey: 'fixture',
          requestedCapabilities: const <ExternalPluginCapability>{
            ExternalPluginCapability.network,
            ExternalPluginCapability.credentials,
          },
        ),
      ),
      executor: executor,
      policy: ExternalPluginTrustPolicy(
        trustedRepositoryOrigins: const <String>{'https://repo.invalid'},
        trustedPayloadSha256: const <String>{'cc'},
        allowedVeneraCapabilities: const <ExternalPluginCapability>{
          ExternalPluginCapability.network,
        },
      ),
    );

    await expectLater(
      host.activate(plugin),
      throwsA(
        isA<ExternalPluginActivationException>().having(
          (error) => error.denials,
          'denials',
          contains(ExternalPluginDenial.capabilityDenied),
        ),
      ),
    );
    expect(executor.calls, 0);
  });

  test('keyless Venera metadata must discover one stable source key', () async {
    final plugin = ExternalComicPluginCatalogEntry(
      format: ExternalComicPluginFormat.veneraJavaScript,
      pluginId: 'venera:https://repo.invalid/keyless.js',
      name: 'Keyless',
      version: '1.0.0',
      entrypoint: Uri.parse('https://repo.invalid/keyless.js'),
      sources: const <ExternalComicPluginSource>[],
      requiresRuntimeDiscovery: true,
    );
    final executor = _Executor(sourceId: 'venera:keyless');
    final host = PermissionedExternalComicPluginHost(
      inspector: _Inspector(
        ExternalPluginInspection(
          format: ExternalComicPluginFormat.veneraJavaScript,
          payloadSha256: 'dd',
        ),
      ),
      executor: executor,
      policy: ExternalPluginTrustPolicy(
        trustedRepositoryOrigins: const <String>{'https://repo.invalid'},
        trustedPayloadSha256: const <String>{'dd'},
      ),
    );

    await expectLater(
      host.activate(plugin),
      throwsA(
        isA<ExternalPluginActivationException>().having(
          (error) => error.denials,
          'denials',
          contains(ExternalPluginDenial.sourceIdentityMismatch),
        ),
      ),
    );
    expect(executor.calls, 0);
  });

  test('activation failure is quarantined before the next attempt', () async {
    final quarantine = MemoryExternalPluginQuarantine();
    final executor = _Executor(
      sourceId: 'venera:fixture',
      failure: StateError('sandbox startup failed'),
    );
    final host = PermissionedExternalComicPluginHost(
      inspector: _Inspector(
        ExternalPluginInspection(
          format: ExternalComicPluginFormat.veneraJavaScript,
          payloadSha256: 'cc',
          sourceKey: 'fixture',
          requestedCapabilities: const <ExternalPluginCapability>{
            ExternalPluginCapability.network,
          },
        ),
      ),
      executor: executor,
      policy: ExternalPluginTrustPolicy(
        trustedRepositoryOrigins: const <String>{'https://repo.invalid'},
        trustedPayloadSha256: const <String>{'cc'},
      ),
      quarantine: quarantine,
    );

    await expectLater(
      host.activate(_veneraPlugin()),
      throwsA(
        isA<ExternalPluginActivationException>().having(
          (error) => error.denials,
          'denials',
          contains(ExternalPluginDenial.activationFailed),
        ),
      ),
    );
    executor.failure = null;
    await expectLater(
      host.activate(_veneraPlugin()),
      throwsA(
        isA<ExternalPluginActivationException>().having(
          (error) => error.denials,
          'denials',
          contains(ExternalPluginDenial.quarantined),
        ),
      ),
    );
    expect(executor.calls, 1);
  });

  test('runtime registry closes colliding plugin sources', () async {
    final firstPlugin = ExternalComicPluginCatalogEntry(
      format: ExternalComicPluginFormat.veneraJavaScript,
      pluginId: 'venera:first',
      name: 'First',
      version: '1.0.0',
      entrypoint: Uri.parse('https://repo.invalid/first.js'),
      sources: const <ExternalComicPluginSource>[
        ExternalComicPluginSource(
          sourceId: 'venera:shared',
          externalId: 'shared',
          name: 'Shared',
          language: 'en',
        ),
      ],
    );
    final firstSession = _Session(
      firstPlugin,
      <BrowsableComicSource>[_Source('venera:shared')],
    );
    final secondPlugin = ExternalComicPluginCatalogEntry(
      format: ExternalComicPluginFormat.veneraJavaScript,
      pluginId: 'venera:second',
      name: 'Second',
      version: '1.0.0',
      entrypoint: Uri.parse('https://repo.invalid/second.js'),
      sources: const <ExternalComicPluginSource>[
        ExternalComicPluginSource(
          sourceId: 'venera:shared',
          externalId: 'shared',
          name: 'Shared',
          language: 'en',
        ),
      ],
    );
    final secondSession = _Session(
      secondPlugin,
      <BrowsableComicSource>[_Source('venera:shared')],
    );
    final host = _QueueHost(<ExternalComicPluginSession>[
      firstSession,
      secondSession,
    ]);
    final registry = ExternalPluginRuntimeRegistry(
      <ExternalComicPluginHost>[host],
    );
    addTearDown(registry.close);

    await registry.activate(firstPlugin);
    await expectLater(
      registry.activate(secondPlugin),
      throwsA(
        isA<ExternalPluginActivationException>().having(
          (error) => error.denials,
          'denials',
          contains(ExternalPluginDenial.sourceIdentityCollision),
        ),
      ),
    );

    expect(firstSession.closed, isFalse);
    expect(secondSession.closed, isTrue);
    expect(registry.activeSources.single.sourceId, 'venera:shared');
  });

  test('runtime registry coalesces concurrent activation', () async {
    final gate = Completer<void>();
    final session = _Session(
      _veneraPlugin(),
      <BrowsableComicSource>[_Source('venera:fixture')],
    );
    final host = _BlockingHost(session: session, gate: gate);
    final registry = ExternalPluginRuntimeRegistry(
      <ExternalComicPluginHost>[host],
    );
    addTearDown(registry.close);

    final first = registry.activate(_veneraPlugin());
    final second = registry.activate(_veneraPlugin());
    expect(host.calls, 1);
    gate.complete();

    final results = await Future.wait(<Future<List<BrowsableComicSource>>>[
      first,
      second,
    ]);
    expect(host.calls, 1);
    expect(results[0].single.sourceId, 'venera:fixture');
    expect(results[1].single.sourceId, 'venera:fixture');
  });

  test('runtime registry owns session deactivation', () async {
    final session = _Session(
      _veneraPlugin(),
      <BrowsableComicSource>[_Source('venera:fixture')],
    );
    final registry = ExternalPluginRuntimeRegistry(
      <ExternalComicPluginHost>[
        _QueueHost(<ExternalComicPluginSession>[session]),
      ],
    );

    await registry.activate(_veneraPlugin());
    expect(registry.isActive('venera:fixture'), isTrue);
    await registry.deactivate('venera:fixture');

    expect(session.closed, isTrue);
    expect(registry.activeSources, isEmpty);
    await registry.close();
  });

  test('runtime source identity mismatch closes and quarantines session',
      () async {
    final quarantine = MemoryExternalPluginQuarantine();
    final executor = _Executor(sourceId: 'venera:other');
    final host = PermissionedExternalComicPluginHost(
      inspector: _Inspector(
        ExternalPluginInspection(
          format: ExternalComicPluginFormat.veneraJavaScript,
          payloadSha256: 'cc',
          sourceKey: 'fixture',
        ),
      ),
      executor: executor,
      policy: ExternalPluginTrustPolicy(
        trustedRepositoryOrigins: const <String>{'https://repo.invalid'},
        trustedPayloadSha256: const <String>{'cc'},
      ),
      quarantine: quarantine,
    );

    await expectLater(
      host.activate(_veneraPlugin()),
      throwsA(
        isA<ExternalPluginActivationException>().having(
          (error) => error.denials,
          'denials',
          contains(ExternalPluginDenial.sourceIdentityMismatch),
        ),
      ),
    );
    expect(executor.lastSession?.closed, isTrue);
    expect(quarantine.reasonFor('venera:fixture'), isNotNull);
  });
}

ExternalPluginTrustPolicy _mihonPolicy() => ExternalPluginTrustPolicy(
      trustedRepositoryOrigins: const <String>{'https://repo.invalid'},
      trustedPayloadSha256: const <String>{'aa'},
      trustedMihonSignerSha256: const <String>{'bb'},
      allowedMihonExtensionLibs: const <String>{'tachiyomix-v1.6'},
      minimumVersionCodes: const <String, int>{
        'mihon:eu.kanade.tachiyomi.extension.en.fixture': 4,
      },
    );

ExternalComicPluginCatalogEntry _mihonPlugin() =>
    ExternalComicPluginCatalogEntry(
      format: ExternalComicPluginFormat.mihonExtension,
      pluginId: 'mihon:eu.kanade.tachiyomi.extension.en.fixture',
      name: 'Fixture',
      version: '1.0.0',
      versionCode: 4,
      entrypoint: Uri.parse('https://repo.invalid/fixture.apk'),
      sources: const <ExternalComicPluginSource>[
        ExternalComicPluginSource(
          sourceId: 'mihon:42',
          externalId: '42',
          name: 'Fixture',
          language: 'en',
        ),
      ],
    );

ExternalComicPluginCatalogEntry _veneraPlugin() =>
    ExternalComicPluginCatalogEntry(
      format: ExternalComicPluginFormat.veneraJavaScript,
      pluginId: 'venera:fixture',
      name: 'Fixture',
      version: '1.0.0',
      entrypoint: Uri.parse('https://repo.invalid/fixture.js'),
      sources: const <ExternalComicPluginSource>[
        ExternalComicPluginSource(
          sourceId: 'venera:fixture',
          externalId: 'fixture',
          name: 'Fixture',
          language: 'en',
        ),
      ],
    );


final class _BlockingHost implements ExternalComicPluginHost {
  _BlockingHost({required this.session, required this.gate});

  final ExternalComicPluginSession session;
  final Completer<void> gate;
  int calls = 0;

  @override
  ExternalComicPluginFormat get format =>
      ExternalComicPluginFormat.veneraJavaScript;

  @override
  Future<ExternalComicPluginSession> activate(
    ExternalComicPluginCatalogEntry plugin,
  ) async {
    calls++;
    await gate.future;
    return session;
  }
}

final class _QueueHost implements ExternalComicPluginHost {
  _QueueHost(this._sessions);

  final List<ExternalComicPluginSession> _sessions;
  int _index = 0;

  @override
  ExternalComicPluginFormat get format =>
      ExternalComicPluginFormat.veneraJavaScript;

  @override
  Future<ExternalComicPluginSession> activate(
    ExternalComicPluginCatalogEntry plugin,
  ) async =>
      _sessions[_index++];
}

final class _Inspector implements ExternalPluginInspector {
  _Inspector(this.inspection);

  final ExternalPluginInspection inspection;

  @override
  ExternalComicPluginFormat get format => inspection.format;

  @override
  Future<ExternalPluginInspection> inspect(
    ExternalComicPluginCatalogEntry plugin,
  ) async =>
      inspection;
}

final class _Executor implements ExternalPluginExecutor {
  _Executor({required this.sourceId, this.failure});

  final String sourceId;
  Object? failure;
  int calls = 0;
  _Session? lastSession;

  @override
  ExternalComicPluginFormat get format => sourceId.startsWith('mihon:')
      ? ExternalComicPluginFormat.mihonExtension
      : ExternalComicPluginFormat.veneraJavaScript;

  @override
  Future<ExternalComicPluginSession> activate(
    ExternalComicPluginCatalogEntry plugin,
    ExternalPluginInspection inspection,
  ) async {
    calls++;
    final error = failure;
    if (error != null) {
      throw error;
    }
    return lastSession = _Session(plugin, <BrowsableComicSource>[
      _Source(sourceId),
    ]);
  }
}

final class _Session implements ExternalComicPluginSession {
  _Session(this.plugin, this.sources);

  @override
  final ExternalComicPluginCatalogEntry plugin;

  @override
  final List<BrowsableComicSource> sources;

  bool closed = false;

  @override
  Future<void> close() async {
    closed = true;
  }
}

final class _Source implements BrowsableComicSource {
  _Source(this.sourceId);

  @override
  final String sourceId;

  @override
  ComicSourceDescriptor get descriptor => ComicSourceDescriptor(
        sourceId: sourceId,
        name: 'Fixture',
        language: 'en',
        website: Uri.parse('https://example.invalid'),
      );

  @override
  Future<SourceBrowsePage> browse({
    String query = '',
    int offset = 0,
    int limit = 24,
  }) async =>
      SourceBrowsePage(
        items: const <SourceComicSummary>[],
        offset: offset,
        hasMore: false,
      );

  @override
  Future<ComicManifest> loadComic(String comicId) async => ComicManifest(
        comic: Comic(
          comicId: comicId,
          sourceId: sourceId,
          title: 'Fixture',
          authors: const <String>[],
          readingDirection: ReadingDirection.ltr,
        ),
        chapters: const <Chapter>[],
      );

  @override
  Future<ChapterManifest> loadChapter(String chapterId) =>
      throw UnsupportedError('not used');

  @override
  Future<Uint8List> loadResource(Uri uri) async => Uint8List(0);
}

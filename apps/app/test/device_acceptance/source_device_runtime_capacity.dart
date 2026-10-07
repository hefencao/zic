part of 'source_device_acceptance.dart';

Future<void> _probeRuntimeCapacity(Directory probeRoot) async {
  await _step<Map<String, Object?>>('runtime', '32-session-boundary', () async {
    final root = Directory('${probeRoot.path}/capacity-'
        '${DateTime.now().microsecondsSinceEpoch}');
    await root.create(recursive: true);
    final sessions = <ExternalComicPluginSession>[];
    final executor = VeneraSandboxExecutor(
      backend: AndroidVeneraSandboxRuntimeBackend(),
    );
    Future<ExternalComicPluginSession> activate(int index) async {
      final key = 'zic-acceptance-$index';
      final payload = File('${root.path}/$key.js');
      await payload.writeAsString('''
class AcceptanceSource extends ComicSource {
 key = "$key";
 name = "Acceptance $index";
 url = "https://example.invalid/";
 version = "1.0.0";
 explore = [{title:"Fixture",type:"multiPartPage",load:async()=>[
   {title:"Group",comics:[{id:"fixture",title:"Fixture $index"}]}
 ]}];
 comic = {loadInfo:async()=>({title:"Fixture",chapters:{one:"One"}})};
}
''', flush: true);
      final plugin = ExternalComicPluginCatalogEntry(
        format: ExternalComicPluginFormat.veneraJavaScript,
        pluginId: 'venera:$key', name: 'Acceptance $index', version: '1.0.0',
        entrypoint: Uri.https('example.invalid', '/$key.js'),
        sources: <ExternalComicPluginSource>[
          ExternalComicPluginSource(sourceId: 'venera:$key',
              externalId: key, name: 'Acceptance $index', language: 'und'),
        ],
      );
      final inspector = VeneraJavaScriptInspector(
        payloads: CallbackExternalPluginPayloadLoader((_) async =>
            ExternalPluginPayloadFile(path: payload.path,
                byteLength: await payload.length())),
      );
      return executor.activate(plugin, await inspector.inspect(plugin));
    }
    try {
      for (var index = 0; index < 32; index++) {
        _status.value = 'runtime capacity ${index + 1}/32';
        final session = await activate(index);
        sessions.add(session);
        if (session.sources.length != 1 ||
            (await session.sources.single.browse()).items.length != 1) {
          throw StateError('activated fixture source is not usable');
        }
      }
      var rejected = false;
      try {
        final unexpected = await activate(32);
        await unexpected.close();
      } on Object catch (error) {
        final message = error.toString().toLowerCase();
        rejected = message.contains('session') && message.contains('limit');
        if (!rejected) rethrow;
      }
      if (!rejected) throw StateError('33rd session exceeded production ceiling');
      for (final session in sessions) {
        if ((await session.sources.single.browse()).items.length != 1) {
          throw StateError('capacity rejection damaged an active source');
        }
      }
      final released = sessions.removeAt(0);
      await released.close();
      final replacement = await activate(32);
      sessions.add(replacement);
      if ((await replacement.sources.single.browse()).items.length != 1) {
        throw StateError('physical close did not release capacity');
      }
      return <String, Object?>{
        'usableSessions': sessions.length,
        'overLimitRejected': rejected,
        'activeSourcesPreserved': 32,
        'releasedCapacityReusable': true,
      };
    } finally {
      for (final session in sessions.reversed) { await session.close(); }
    }
  }, (result) => result);
}

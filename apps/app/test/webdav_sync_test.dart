import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:network_bridge/network_bridge.dart';
import 'package:catalog/catalog.dart';
import 'package:comic_translation/comic_translation.dart';
import 'package:downloads/downloads.dart';
import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sessions/sessions.dart';
import 'package:zic/app_preferences.dart';
import 'package:zic/library_sync.dart';
import 'package:zic/library_data_scope.dart';
import 'package:zic/library_sync_store.dart';
import 'package:zic/portable_settings.dart';
import 'package:zic/home_shell.dart' show chapterRequiresSourceLocatorRefresh;
import 'package:zic/home_reader_composition.dart';
import 'package:zic/source_resource_gateway.dart';
import 'package:telemetry/telemetry.dart';
import 'package:zic/webdav_sync.dart';
import 'package:zic/webdav_snapshots.dart';
import 'package:zic/webdav_repository.dart';

void main() {
  test('scoped sync preserves excluded registers and restores them when selected again', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav, portable: true);
    final b = await _Device.create(dav, portable: true);
    await a.seed();
    a.preferences.setReaderStartsImmersive(false);
    await a.controller.synchronize();
    final before = selectLibraryData(decodeLibrarySync(dav.payload!), {
      LibraryDataSection.shelf, LibraryDataSection.history, LibraryDataSection.readingSettings,
    }).map((key, record) => MapEntry(key, record.toJson()));
    await b.controller.saveConfiguration(dav.config, sections: {LibraryDataSection.appSettings});
    b.preferences.setShelfPluginFilterExpanded(true);
    await b.controller.synchronize();
    expect(await b.store.list(), isEmpty);
    expect(await b.store.listSavedComics(), isEmpty);
    expect(b.preferences.readerStartsImmersive, isTrue);
    final after = selectLibraryData(decodeLibrarySync(dav.payload!), {
      LibraryDataSection.shelf, LibraryDataSection.history, LibraryDataSection.readingSettings,
    }).map((key, record) => MapEntry(key, record.toJson()));
    expect(after, before, reason: 'unchecked cloud registers retain payload, clock and writer');
    expect((b.files['state.json']!['versions']! as Map).keys.every((key) =>
      libraryDataSection(key as String) == LibraryDataSection.appSettings), isTrue);
    await b.restart();
    expect(b.controller.sections, {LibraryDataSection.appSettings});
    await b.controller.saveConfiguration(dav.config, sections: {LibraryDataSection.history});
    await b.controller.synchronize();
    expect((await b.store.get('remote', 'chapter'))!.progress!.pageIndex, 2);
    expect(await b.store.listSavedComics(), isEmpty);
    await a.store.saveProgress(_progress(1, DateTime.now().toUtc().add(const Duration(seconds: 1))));
    await a.controller.synchronize();
    final historyClock = jsonEncode(selectLibraryData(Map<String, Object?>.from(
      b.files['state.json']!['versions']! as Map), {LibraryDataSection.history}));
    await b.controller.saveConfiguration(dav.config, sections: {LibraryDataSection.appSettings});
    await b.controller.synchronize();
    expect((await b.store.get('remote', 'chapter'))!.progress!.pageIndex, 2);
    expect(jsonEncode(selectLibraryData(Map<String, Object?>.from(
      b.files['state.json']!['versions']! as Map), {LibraryDataSection.history})), historyClock);
    await b.controller.saveConfiguration(dav.config, sections: allLibraryDataSections);
    await b.controller.synchronize();
    expect((await b.store.get('remote', 'chapter'))!.progress!.pageIndex, 1);
    expect(await b.store.listSavedComics(), hasLength(1));
    expect(b.preferences.readerStartsImmersive, isFalse);
    final stable = dav.payload;
    await b.controller.synchronize();
    expect(dav.payload, stable);
  });

  test('new repositories use stable names with versions only inside metadata', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    await a.controller.synchronize();
    expect(dav.files.keys, containsAll(['/dav/zic/latest.json', '/dav/zic/repository.json']));
    expect(dav.files.keys.any((path) => RegExp(r'/(?:objects|backups|latest|repository)-v\d').hasMatch(path)), isFalse);
    expect(dav.files.keys.any((path) => path.startsWith('/dav/zic/objects/')), isTrue);
    expect(dav.files.keys.any((path) => path.startsWith('/dav/zic/backups/')), isTrue);
    final directories = Set<String>.of(dav.directories);
    await a.restart();
    await a.controller.synchronize();
    expect(dav.directories, directories, reason: 'restarting never creates a new version or generation directory');
  });

  test('cancelling repository discovery does not start legacy probes or create files', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    dav.intercept = (request) async {
      if (request.method != 'GET' || !request.uri.path.endsWith('/repository.json')) return false;
      request.response.statusCode = 404;
      unawaited(a.controller.cancel());
      return true;
    };
    await expectLater(a.controller.synchronize(), throwsA(isA<WebDavException>()));
    expect(dav.paths, ['GET /dav/zic/repository.json']);
    expect(dav.files, isEmpty);
    expect(a.controller.busy, isFalse);
  });

  test('existing v3 coordination and head stay single while both object layouts remain readable', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    await a.controller.synchronize();
    final original = Map<String, List<int>>.of(dav.files);
    dav.files.clear();
    dav.directories.clear();
    for (final entry in original.entries) {
      final path = entry.key.replaceAll('/repository.json', '/repository-v3.json')
        .replaceAll('/latest.json', '/latest-v2.json')
        .replaceAll('/objects/', '/objects-v3/').replaceAll('/backups/', '/backups-v3/');
      var bytes = entry.value;
      if (path.endsWith('/repository-v3.json')) {
        final state = jsonDecode(utf8.decode(bytes)) as Map;
        state.remove('head');
        bytes = utf8.encode(jsonEncode(state));
      } else if (path.endsWith('.json')) {
        bytes = utf8.encode(utf8.decode(bytes).replaceAll('objects/', 'objects-v3/')
          .replaceAll('backups/', 'backups-v3/'));
      }
      dav._put(path, bytes);
    }
    final old = Map<String, List<int>>.of(dav.files);
    final b = await _Device.create(dav);
    await b.controller.synchronize();
    expect((await b.store.get('remote', 'chapter'))!.progress!.pageIndex, 2);
    await b.store.saveProgress(_progress(1, DateTime.now().toUtc().add(const Duration(seconds: 1))));
    dav.paths.clear();
    await b.controller.synchronize();
    expect(dav.paths.where((path) => path.startsWith('PUT ') && path.endsWith('.json.gz')), hasLength(1),
      reason: 'unchanged shards reuse validated old paths in the same generation');
    await a.controller.synchronize();
    expect((await a.store.get('remote', 'chapter'))!.progress!.pageIndex, 1);
    expect(dav.files, isNot(contains('/dav/zic/latest.json')));
    expect(dav.files, isNot(contains('/dav/zic/repository.json')));
    expect(dav.files.keys.where((path) => RegExp(r'/backups(?:-v3)?/\d{4}-\d{2}-\d{2}\.json$').hasMatch(path)), hasLength(1));
    for (final entry in old.entries.where((entry) => entry.key.contains('/objects-v3/') || entry.key.contains('/backups-v3/'))) {
      expect(dav.files[entry.key], entry.value, reason: 'layout cleanup does not delete historical data');
    }
    expect(dav.files.keys.any((path) => path.contains('/objects/')), isTrue);
    await a.restart();
    await a.controller.synchronize();
    expect(a.controller.lastResult!.pending, 0);
  });

  test('legacy head without coordination retains its original commit point', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    final values = await a.controller.exportRecords();
    await dav.replace(encodeLibrarySync(values), forceV2: true);
    dav._put(dav.config.legacyLatest.path, dav.files.remove(dav.config.latest.path)!);
    a.files['state.json']!['remoteProtocol'] = 2;
    await a.restart();
    await a.controller.synchronize();
    expect(dav.files, isNot(contains(dav.config.latest.path)));
    final coordination = jsonDecode(utf8.decode(dav.files['/dav/zic/repository.json']!)) as Map;
    expect(coordination['head'], 'latest-v2.json');
    await a.restart();
    await a.controller.synchronize();
    expect(a.controller.lastResult!.pending, 0);
    dav.files.remove(dav.config.legacyLatest.path);
    await expectLater(a.controller.synchronize(), throwsA(isA<WebDavException>()));
    expect(a.controller.error, contains('最新同步索引缺失'));
  });

  test('portable settings merge across devices and a manual restore becomes a new synchronized edit', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav, portable: true);
    final b = await _Device.create(dav, portable: true);
    await a.seed();
    a.preferences.setShelfPluginFilterExpanded(true);
    a.translation!.values['targetLanguage'] = 'en';
    await a.translation!.save();
    await a.translation!.setComic('remote', 'comic', {'enabled': true, 'sourceLanguage': 'ja',
      'ocrMaxAnalysisSide': 2240});
    await a.store.saveSourcePreference(ComicSourcePreference(sourceId: 'remote', enabled: false,
      sortOrder: 4, updatedAt: DateTime.now().toUtc()));
    await a.controller.synchronize();
    await b.controller.synchronize();
    expect(b.preferences.shelfPluginFilterExpanded, isTrue);
    expect(b.translation!.values['targetLanguage'], 'en');
    expect(b.translation!.forComic('remote', 'comic')['sourceLanguage'], 'ja');
    expect((await b.store.listSourcePreferences()).single.enabled, isFalse);
    final backup = await a.controller.exportRecords();
    b.translation!.values['targetLanguage'] = 'zh-CN';
    await b.translation!.save();
    await b.translation!.resetComicOcr('remote', 'comic');
    await b.controller.synchronize();
    await a.controller.synchronize();
    expect(a.translation!.values['targetLanguage'], 'zh-CN');
    expect(a.translation!.hasComicOcrOverride('remote', 'comic'), isFalse);
    await a.controller.importRecords(backup);
    await a.controller.synchronize();
    await b.controller.synchronize();
    expect(b.translation!.values['targetLanguage'], 'en');
    expect(b.translation!.forComic('remote', 'comic')['ocrMaxAnalysisSide'], 2240);
    final stable = dav.payload;
    await a.controller.synchronize();
    await b.controller.synchronize();
    expect(dav.payload, stable, reason: 'restored settings must settle without repeated uploads');
  });

  test('an unedited plugin observation adopts an existing choice while explicit edits win', () async {
    const key = 'setting:plugin\u0000["venera:test","choice"]';
    final remote = LibrarySyncRecord(key: key, time: 0, writer: 'a', data: {'kind': 'text', 'value': 'saved'});
    final observed = LibrarySyncRecord(key: key, time: 0, writer: 'z', data: {'kind': 'text', 'value': 'default'});
    expect((await prepareWebDavSnapshot({key: observed}, {key: remote})).records[key]!.data!['value'], 'saved');
    final edit = LibrarySyncRecord(key: key, time: 10, writer: 'z', data: observed.data);
    expect((await prepareWebDavSnapshot({key: edit}, {key: remote})).records[key]!.data!['value'], 'default');
  });

  test('two devices merge shelf, backwards progress, categories and reading settings', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    final b = await _Device.create(dav);
    await a.seed();
    a.preferences.setReaderStartsImmersive(false);
    await a.controller.testConnection();
    expect(dav.methods, ['PROPFIND']);
    await a.controller.synchronize();
    await b.controller.synchronize();
    expect((await b.store.get('remote', 'chapter'))!.progress!.pageIndex, 2);
    expect((await b.store.getComicPreference('remote', 'comic'))!.liked, isTrue);
    expect((await b.store.listCategories()).single.name, 'Favorites');
    expect(b.preferences.readerStartsImmersive, isFalse);
    expect((await b.store.listAllChapterReadStates()).single.isRead, isTrue);
    await b.store.saveProgress(_progress(1, DateTime.now().toUtc().add(const Duration(seconds: 1))));
    await b.controller.synchronize();
    await a.controller.synchronize();
    expect((await a.store.get('remote', 'chapter'))!.progress!.pageIndex, 1,
      reason: 'a later backwards read must not be replaced by the highest page');
    await a.store.removeCategory('favorites');
    await a.controller.synchronize();
    await b.controller.synchronize();
    expect(await b.store.listCategories(), isEmpty);
    expect((await b.store.getComicPreference('remote', 'comic'))!.categoryIds, isEmpty);
    final stable = dav.payload;
    await a.controller.synchronize();
    await b.controller.synchronize();
    expect(jsonDecode(utf8.decode(dav.payload!)), jsonDecode(utf8.decode(stable!)));
    expect(a.controller.lastResult!.pending, 0);
    expect(b.controller.lastResult!.pending, 0);
  });

  test('deletions survive offline retry and controller restart', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    final b = await _Device.create(dav);
    await a.seed();
    await a.controller.synchronize();
    await b.controller.synchronize();
    await a.store.removeSavedComic('remote', 'comic');
    await a.store.removeChapter('remote', 'chapter');
    dav.intercept = (request) async {
      if (request.method != 'GET' || !request.uri.path.endsWith('/repository.json')) return false;
      final versions = a.files['state.json']!['versions']! as Map;
      expect((versions['comic:remote\u0000comic']! as Map)['hash'], syncFingerprint(null),
        reason: 'deletion intent must be durable before registration network IO');
      request.response.statusCode = 403;
      return true;
    };
    await expectLater(a.controller.synchronize(), throwsA(isA<WebDavException>()));
    dav.intercept = null;
    dav.putStatus = 503;
    await expectLater(a.controller.synchronize(), throwsA(isA<WebDavException>()));
    await a.restart();
    dav.putStatus = null;
    await a.controller.synchronize();
    await b.controller.synchronize();
    expect(await b.store.getSavedComic('remote', 'comic'), isNull);
    expect(await b.store.get('remote', 'chapter'), isNull);
    await b.controller.synchronize();
    expect(decodeLibrarySync(dav.payload!)['chapter:remote\u0000chapter']!.deleted, isTrue);
    final journal = jsonEncode(a.files['state.json']);
    expect(journal, isNot(contains('https://')));
    expect(journal, isNot(contains('password')));
  });

  test('conditional write retries a real 412 and preserves the other writer', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    dav.beforePut = () async {
      dav.beforePut = null;
      final category = LibraryCategory(categoryId: 'other', name: 'Other device',
        sortOrder: 1, createdAt: DateTime.utc(2026));
      await dav.replace(encodeLibrarySync({'category:other': LibrarySyncRecord(
        key: 'category:other', time: DateTime.utc(2026).microsecondsSinceEpoch,
        writer: 'other', data: category.toJson())}), forceV2: true);
    };
    await a.controller.synchronize();
    expect(dav.conflicts, 1);
    expect(dav.conditions.first, '*');
    expect(dav.conditions.last, dav.previousEtag);
    expect((await a.store.listCategories()).map((c) => c.categoryId),
      containsAll(['favorites', 'other']));
    expect(decodeLibrarySync(dav.payload!), contains('comic:remote\u0000comic'));
  });

  test('local edits made during HTTP are preserved and uploaded on the next sync', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    final b = await _Device.create(dav);
    await a.seed();
    await a.controller.synchronize();
    await b.controller.synchronize();
    await a.store.saveProgress(_progress(0, DateTime.now().toUtc().add(const Duration(seconds: 1))));
    await a.controller.synchronize();
    dav.beforeGet = () async {
      dav.beforeGet = null;
      await b.store.saveProgress(_progress(1, DateTime.now().toUtc().add(const Duration(seconds: 2))));
    };
    await b.controller.synchronize();
    expect((await b.store.get('remote', 'chapter'))!.progress!.pageIndex, 1);
    expect(b.controller.lastResult!.pending, greaterThan(0));
    await b.controller.synchronize();
    expect(ReadingProgress.fromJson(decodeLibrarySync(dav.payload!)
      ['progress:remote\u0000chapter']!.data!).pageIndex, 1);
  });

  test('invalid cloud identity, duplicate records and weak ETags never overwrite', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    final valid = LibrarySyncRecord(key: 'progress:remote\u0000chapter', time: 1,
      writer: 'other', data: _progress(0, DateTime.utc(2026)).toJson()).toJson();
    for (final records in [
      [{...valid, 'key': 'progress:wrong\u0000chapter'}], [valid, valid],
    ]) {
      await dav.replace(utf8.encode(jsonEncode({'format': librarySyncFormat, 'records': records})));
      await expectLater(a.controller.synchronize(), throwsA(isA<FormatException>()));
      expect((await a.store.get('remote', 'chapter'))!.progress!.pageIndex, 2);
      expect(dav.conditions, isEmpty);
    }
    await dav.replace(encodeLibrarySync({}));
    dav.weakEtag = true;
    await expectLater(a.controller.synchronize(), throwsA(isA<WebDavException>()));
    expect(dav.conditions, isEmpty);
  });

  test('local files and source settings stay private; local progress waits for import', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    final b = await _Device.create(dav);
    final local = ImportedChapterRecord.folder(directoryId: '/private/comic',
      displayName: 'Local', pages: const [ImportedPageRecord(displayName: '1.png',
        sourceId: '/private/comic/1.png', contentKindHint: ContentKindHint.png)]);
    await a.store.upsertChapter(local);
    await a.store.saveProgress(ReadingProgress(sourceId: local.sourceId,
      comicId: local.comicId, chapterId: local.chapterId, pageIndex: 0,
      subPageOffset: .5, readerMode: ReaderMode.paged, updatedAt: DateTime.now().toUtc()));
    await a.controller.synchronize();
    final text = utf8.decode(dav.payload!);
    expect(text, isNot(contains('/private/comic/1.png')));
    expect(text, isNot(contains('directoryId')));
    expect(text, isNot(contains('dummy-secret')));
    await b.controller.synchronize();
    expect(await b.store.get(local.sourceId, local.chapterId), isNull);
    expect(b.controller.lastResult!.pending, greaterThan(0));
    await b.store.upsertChapter(local);
    await b.controller.synchronize();
    expect((await b.store.get(local.sourceId, local.chapterId))!.progress!.subPageOffset, .5);
  });

  test('queued and running cancellation only drains owned lane tasks', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final lane = NetLane(maxActive: 1);
    final blocker = Completer<void>();
    var unrelatedCancelled = false;
    lane.submit(key: 'reader', priority: 1000, task: (control) async {
      unawaited(control.whenCancelled.then((_) => unrelatedCancelled = true));
      await blocker.future;
    });
    final client = WebDavClient(lane);
    final queued = client.testConnection(dav.config);
    final queuedError = expectLater(queued, throwsA(isA<WebDavException>()));
    await client.cancel();
    await queuedError;
    expect(lane.running, 1);
    expect(unrelatedCancelled, isFalse);
    expect(dav.methods, isEmpty);
    blocker.complete();
    await lane.idle();
    final entered = Completer<void>();
    final release = Completer<void>();
    dav.hold = (request) async {
      request.response.statusCode = 200;
      request.response.write('partial');
      await request.response.flush();
      entered.complete();
      await release.future;
    };
    final running = client.request(dav.config, 'GET', dav.config.file);
    final runningError = expectLater(running, throwsA(isA<WebDavException>()));
    await entered.future;
    await client.cancel().timeout(const Duration(seconds: 2));
    await runningError;
    expect(lane.running, 0);
    release.complete();
    await client.close();
  });

  test('body timeout and response size limits retire physical lane work', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final lane = NetLane(maxActive: 1);
    final client = WebDavClient(lane, timeout: const Duration(milliseconds: 150));
    addTearDown(client.close);
    final release = Completer<void>();
    dav.hold = (request) async {
      request.response.write('partial');
      await request.response.flush();
      await release.future;
    };
    await expectLater(client.request(dav.config, 'GET', dav.config.file),
      throwsA(isA<WebDavException>().having((e) => e.message, 'message', contains('超时'))));
    await lane.idle();
    expect(lane.running, 0);
    release.complete();
    dav.hold = null;
    await dav.replace(List.filled(1024, 65));
    await expectLater(client.request(dav.config, 'GET', dav.config.file, maxBytes: 16),
      throwsA(isA<WebDavException>().having((e) => e.message, 'message', contains('大小'))));
    await lane.idle();
    expect(lane.running, 0);
  });

  test('file requests can use a bounded transfer deadline independent of connection tests', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    dav.hold = (request) async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      request.response.write('complete');
    };
    final client = WebDavClient(NetLane(maxActive: 1),
      timeout: const Duration(milliseconds: 10));
    addTearDown(client.close);
    final response = await client.request(dav.config, 'GET', dav.config.file,
      requestTimeout: const Duration(seconds: 2));
    expect(utf8.decode(response.bytes), 'complete');
  });

  test('compressed cloud expansion is bounded before write or local application', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    await dav.replace(utf8.encode(jsonEncode({
      'format': librarySyncFormat,
      'recordsGzip': base64Encode(const MetadataGzipCodec().encode(
        Uint8List(maxLibrarySyncBytes + 1))),
    })));
    await expectLater(a.controller.synchronize(), throwsA(isA<LibrarySyncFormatException>()
      .having((e) => e.message, 'size', contains('32 MiB'))));
    expect(dav.conditions, isEmpty);
    expect((await a.store.get('remote', 'chapter'))!.progress!.pageIndex, 2);
  });

  test('pre-request TLS interruptions reconnect finitely before one real write', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final lane = NetLane(maxActive: 1);
    final client = WebDavClient(lane);
    addTearDown(client.close);
    final faults = _HttpFaults(failures: const [
      HandshakeException('Connection terminated during handshake'),
      HandshakeException('Connection terminated during handshake'),
    ]);
    final retries = <int>[];
    final clock = Stopwatch()..start();
    await HttpOverrides.runWithHttpOverrides(() async {
      final response = await client.request(dav.config, 'PUT', dav.config.file,
        bytes: const [1], headers: const {'If-None-Match': '*'}, onRetry: retries.add);
      expect(response.status, 201);
    }, faults);
    await lane.idle();
    expect(faults.opens, 3);
    expect(retries, [2, 3]);
    expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(1500));
    expect(dav.methods, ['PUT']);
    expect(dav.conditions, ['*']);
    expect(lane.running, 0);
  });

  test('certificate failures and interrupted sent writes are not replayed', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final lane = NetLane(maxActive: 1);
    final client = WebDavClient(lane);
    addTearDown(client.close);
    final certificate = _HttpFaults(failures: const [HandshakeException(
      'private-endpoint', OSError('CERTIFICATE_VERIFY_FAILED private-endpoint', 1))]);
    await HttpOverrides.runWithHttpOverrides(() async {
      await expectLater(client.request(dav.config, 'GET', dav.config.file),
        throwsA(isA<WebDavException>()
          .having((e) => e.message, 'verified certificate failure', contains('证书校验失败'))
          .having((e) => e.message, 'redaction', isNot(contains('private-endpoint')))));
    }, certificate);
    expect(certificate.opens, 1);
    expect(dav.methods, isEmpty);
    final sent = _HttpFaults(failAfterResponse: true);
    await HttpOverrides.runWithHttpOverrides(() async {
      await expectLater(client.request(dav.config, 'PUT', dav.config.file,
        bytes: const [1], headers: const {'If-None-Match': '*'}),
        throwsA(isA<WebDavException>().having((e) => e.message, 'phase', contains('发送请求'))));
    }, sent);
    await lane.idle();
    expect(sent.opens, 1);
    expect(dav.methods, ['PUT']);
    expect(dav.conditions.length, 1);
    final repeated = _HttpFaults(failures: List.filled(6,
      const HandshakeException('Connection terminated during handshake')));
    await HttpOverrides.runWithHttpOverrides(() async {
      await expectLater(client.testConnection(dav.config),
        throwsA(isA<WebDavException>().having((e) => e.message, 'TLS', contains('HANDSHAKE_INTERRUPTED'))));
    }, repeated);
    await lane.idle();
    expect(repeated.opens, WebDavClient.maxAttempts);
    expect(dav.methods, ['PUT']);
    expect(lane.running, 0);
  });

  test('a truncated GET retries the read without exposing partial bytes', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    var connections = 0;
    server.listen((socket) {
      final first = connections++ == 0;
      var replied = false;
      socket.listen((_) async {
        if (replied) return;
        replied = true;
        socket.write('HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\n' +
          (first ? 'part' : 'complete'));
        await socket.flush();
        await socket.close();
      });
    });
    final client = WebDavClient(NetLane(maxActive: 1));
    addTearDown(client.close);
    final config = WebDavConfig(address: 'http://127.0.0.1:${server.port}/dav/');
    final response = await client.request(config, 'GET', config.file);
    expect(utf8.decode(response.bytes), 'complete');
    expect(connections, 2);
  });

  test('transient HTTP responses retry with Retry-After and permanent errors stop', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final client = WebDavClient(NetLane(maxActive: 1));
    addTearDown(client.close);
    dav.hold = (request) async {
      request.response.statusCode = dav.methods.length == 1 ? 503 : 207;
      request.response.headers.set(HttpHeaders.retryAfterHeader, '1');
    };
    final clock = Stopwatch()..start();
    await client.testConnection(dav.config);
    expect(dav.methods, ['PROPFIND', 'PROPFIND']);
    expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(1000));
    for (final status in [401, 403, 429]) {
      dav.methods.clear();
      dav.hold = (request) async {
        request.response.statusCode = status;
        // A server-requested wait longer than the remaining deadline is not
        // shortened into an immediate retry or a false success.
        request.response.headers.set(HttpHeaders.retryAfterHeader, '120');
      };
      await expectLater(client.testConnection(dav.config), throwsA(isA<WebDavException>()));
      expect(dav.methods, ['PROPFIND']);
    }
  });

  test('retry backoff cancels immediately and keeps the original total deadline', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final lane = NetLane(maxActive: 1);
    final client = WebDavClient(lane);
    addTearDown(client.close);
    final faults = _HttpFaults(failures: List.filled(5, const SocketException('offline')));
    await HttpOverrides.runWithHttpOverrides(() async {
      final waiting = Completer<void>();
      final request = client.request(dav.config, 'GET', dav.config.file,
        onRetry: (_) => waiting.complete());
      final failed = expectLater(request, throwsA(isA<WebDavException>()
        .having((e) => e.message, 'cancellation', contains('取消'))));
      await waiting.future;
      expect(lane.running, 1);
      final clock = Stopwatch()..start();
      await client.cancel().timeout(const Duration(milliseconds: 400));
      await failed;
      expect(clock.elapsedMilliseconds, lessThan(400));
      expect(faults.opens, 1);
      expect(lane.running, 0);
      await expectLater(client.request(dav.config, 'GET', dav.config.file,
        requestTimeout: const Duration(milliseconds: 100)), throwsA(isA<WebDavException>()));
      expect(faults.opens, 2, reason: 'a 500ms retry must not extend a 100ms deadline');
    }, faults);
    expect(dav.methods, isEmpty);
  });

  test('lost MKCOL acknowledgement recovers from an already-created collection', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final client = WebDavClient(NetLane(maxActive: 1));
    addTearDown(client.close);
    final faults = _HttpFaults(failAfterResponse: true, failMethod: 'MKCOL');
    await HttpOverrides.runWithHttpOverrides(() => client.ensureCollection(dav.config), faults);
    expect(dav.collection, isTrue);
    expect(dav.methods, ['MKCOL', 'MKCOL']);
  });

  test('lost PUT acknowledgement is confirmed by reading without a duplicate write', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    final faults = _HttpFaults(failAfterResponse: true, failMethod: 'PUT', failPath: '/latest.json');
    await HttpOverrides.runWithHttpOverrides(a.controller.synchronize, faults);
    expect(dav.headMethods, ['GET', 'PUT', 'GET']);
    expect(dav.conditions, ['*']);
    expect(a.controller.error, isNull);
    expect(a.controller.lastResult!.pending, 0);
  });

  test('uncertain PUT remerges remote and local edits using a fresh ETag', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    final faults = _HttpFaults(failAfterResponse: true, failMethod: 'PUT', failPath: '/latest.json', afterResponse: () async {
      final category = LibraryCategory(categoryId: 'other', name: 'Other device',
        sortOrder: 1, createdAt: DateTime.utc(2026));
      final records = decodeLibrarySync(dav.payload!);
      records['category:other'] = LibrarySyncRecord(key: 'category:other', time: 1,
        writer: 'other', data: category.toJson());
      await dav.replace(encodeLibrarySync(records));
      await a.store.saveProgress(_progress(1, DateTime.now().toUtc().add(const Duration(seconds: 1))));
    });
    await HttpOverrides.runWithHttpOverrides(a.controller.synchronize, faults);
    expect(dav.headMethods, ['GET', 'PUT', 'GET', 'PUT']);
    expect(dav.conditions.first, '*');
    expect(dav.conditions.last, dav.previousEtag);
    expect(dav.conflicts, 0);
    expect((await a.store.listCategories()).map((c) => c.categoryId), contains('other'));
    final records = decodeLibrarySync(dav.payload!);
    expect(ReadingProgress.fromJson(records['progress:remote\u0000chapter']!.data!).pageIndex, 1);
    expect(a.controller.lastResult!.pending, 0);
  });

  test('transient PUT status recovers by rereading rather than blind replay', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    dav.beforePut = () async {
      dav.putStatus = dav.conditions.length < 3 ? 503 : null;
    };
    await a.controller.synchronize();
    expect(dav.headMethods, ['GET', 'PUT', 'GET', 'PUT', 'GET', 'PUT']);
    expect(a.controller.lastResult!.pending, 0);
  });

  test('cancel and close interrupt write reconciliation backoff without another read', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    for (final close in [false, true]) {
      final a = await _Device.create(dav);
      await a.seed();
      await a.store.saveProgress(_progress(1,
        DateTime.now().toUtc().add(Duration(seconds: close ? 3 : 2))));
      dav.methods.clear();
      dav.headMethods.clear();
      final waiting = Completer<void>();
      a.controller.addListener(() {
        if (a.controller.message?.contains('重新核对云端') == true && !waiting.isCompleted) {
          waiting.complete();
        }
      });
      final faults = _HttpFaults(failAfterResponse: true, failMethod: 'PUT', failPath: '/latest.json');
      await HttpOverrides.runWithHttpOverrides(() async {
        final failed = expectLater(a.controller.synchronize(), throwsA(isA<WebDavException>()));
        await waiting.future;
        await (close ? a.controller.close() : a.controller.cancel())
          .timeout(const Duration(milliseconds: 400));
        await failed;
      }, faults);
      expect(dav.headMethods, ['GET', 'PUT']);
      expect(a.controller.busy, isFalse);
      expect(a.controller.lastResult, isNull);
    }
  });

  test('register merge is deterministic and deletion wins timestamp ties', () {
    final live = LibrarySyncRecord(key: 'category:a', time: 3, writer: 'z',
      data: LibraryCategory(categoryId: 'a', name: 'A', sortOrder: 0,
        createdAt: DateTime.utc(2026)).toJson());
    final deleted = LibrarySyncRecord(key: live.key, time: 3, writer: 'a', data: null);
    final left = mergeLibrarySync({live.key: live}, {deleted.key: deleted});
    final right = mergeLibrarySync({deleted.key: deleted}, {live.key: live});
    expect(encodeLibrarySync(left), encodeLibrarySync(right));
    expect(left[live.key]!.deleted, isTrue);
  });

  test('history-only chapters do not become saved shelf comics during synchronization', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    final b = await _Device.create(dav);
    await a.seed();
    await a.store.removeSavedComic('remote', 'comic');
    await a.store.saveComicPreference((await a.store.getComicPreference('remote', 'comic'))!
      .copyWith(inShelf: false, updatedAt: DateTime.now().toUtc()));
    await a.controller.synchronize();
    await b.controller.synchronize();
    expect(await b.store.getSavedComic('remote', 'comic'), isNull);
    expect((await b.store.get('remote', 'chapter'))!.progress!.pageIndex, 2);
    expect((await b.store.getComicPreference('remote', 'comic'))!.inShelf, isFalse);
    expect(b.controller.lastResult!.pending, 0);
  });

  test('reader settings reject unknown fields and preserve comic overrides and deletion', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    final b = await _Device.create(dav);
    const custom = ComicReaderSettings(enabled: true, directionOverride: ReadingDirection.rtl,
      verticalStitchOverride: true, invertPageOrder: true);
    a.preferences.setComicReaderSettings('remote', 'comic', custom);
    await a.controller.synchronize();
    await b.controller.synchronize();
    expect(b.preferences.readSyncReadingSettings()['reader:remote\u0000comic'], custom.toJson());
    b.preferences.clearComicReaderSettings('remote', 'comic');
    await b.controller.synchronize();
    await a.controller.synchronize();
    expect(a.preferences.readSyncReadingSettings().containsKey('reader:remote\u0000comic'), isFalse);
    final records = decodeLibrarySync(dav.payload!);
    final global = records['reader:global']!;
    records[global.key] = LibrarySyncRecord(key: global.key, time: global.time + 1,
      writer: 'other', data: {...global.data!, 'privateKey': 'reject-me'});
    await dav.replace(encodeLibrarySync(records));
    final count = dav.conditions.length;
    await expectLater(a.controller.synchronize(), throwsA(isA<FormatException>()));
    expect(dav.conditions.length, count);
    expect(a.preferences.readSyncReadingSettings()['reader:global'], global.data);
  });

  test('connection normalization, profile switch and disconnect keep cloud intact', () async {
    expect(() => WebDavConfig(address: 'https://user:secret@example.test/dav'), throwsFormatException);
    expect(() => WebDavConfig(address: 'https://example.test/dav?secret=1'), throwsFormatException);
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    expect(a.controller.config!.file.path, '/dav/zic/library-v1.json');
    final client = WebDavClient(NetLane(maxActive: 1));
    await expectLater(client.request(dav.config, 'GET', Uri.parse('https://other.test/')),
      throwsA(isA<WebDavException>()));
    await client.close();
    expect(dav.methods, isEmpty);
    await a.seed();
    await a.controller.synchronize();
    final payload = dav.payload;
    await a.controller.saveConfiguration(WebDavConfig(address: dav.config.base.toString(), username: 'another'));
    expect(a.files['state.json']!['versions'], isEmpty);
    await a.controller.disconnect();
    expect(a.controller.config, isNull);
    expect(a.files['connection.json']!.containsKey('password'), isFalse);
    expect(dav.payload, payload);
    expect(dav.methods, isNot(contains('DELETE')));
  });

  test('comic preference capacity eviction does not delete settings on other devices', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    const custom = ComicReaderSettings(enabled: true, invertPageOrder: true);
    a.preferences.setComicReaderSettings('remote', 'original', custom);
    await a.controller.synchronize();
    for (var i = 0; i < 512; i++) {
      a.preferences.setComicReaderSettings('remote', 'other-$i', custom);
    }
    expect(a.preferences.readSyncReadingSettings().containsKey('reader:remote\u0000original'), isFalse);
    await a.controller.synchronize();
    expect(decodeLibrarySync(dav.payload!)['reader:remote\u0000original']!.data, custom.toJson());
    expect(a.preferences.readSyncReadingSettings().containsKey('reader:remote\u0000original'), isFalse);
    expect(a.controller.lastResult!.pending, 0);
  });

  test('sync strips encoded source credentials and refreshes logical chapters before Reader', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    final b = await _Device.create(dav);
    final payload = base64Url.encode(utf8.encode(jsonEncode({
      'kind': 'resource', 'url': 'https://example.test/image',
      'headers': {'Cookie': 'account-session-secret', 'Authorization': 'Bearer source-key'},
      'bodyBase64': base64Encode(utf8.encode('private-request-body')),
      'retryChapterId': 'chapter', 'retryPageIndex': 0,
    })));
    final locator = 'mihon:resource:$payload';
    final chapter = ImportedChapterRecord(directoryId: 'private-runtime-directory',
      displayName: 'Private resource', sourceId: 'mihon:fixture', comicId: 'comic',
      chapterId: 'chapter', sourceRevision: 'r1', coverSourceId: locator,
      pages: [ImportedPageRecord(displayName: locator, sourceId: locator,
        pageId: locator, contentKindHint: ContentKindHint.png)]);
    final unsafe = chapter.toJson()
      ..['directoryId'] = chapter.sourceId + ':' + chapter.comicId
      ..remove('coverSourceId');
    final key = 'chapter:' + chapterLibraryIdentity(chapter.sourceId, chapter.chapterId);
    expect(() => decodeLibrarySync(utf8.encode(jsonEncode({
      'format': librarySyncFormat, 'records': [LibrarySyncRecord(
        key: key, time: 1, writer: 'unsafe', data: unsafe).toJson()],
    }))), throwsFormatException);
    await a.store.upsertChapter(chapter);
    await a.store.upsertSavedComic(SavedComicRecord(sourceId: chapter.sourceId,
      comicId: chapter.comicId, title: 'Comic', coverSourceId: locator));
    await a.controller.synchronize();
    final text = utf8.decode(dav.payload!);
    expect(text, isNot(contains(payload)));
    expect(text, isNot(contains('account-session-secret')));
    expect(text, isNot(contains('private-runtime-directory')));
    expect((await a.store.get(chapter.sourceId, chapter.chapterId))!.chapter.pages.single.sourceId,
      locator, reason: 'synchronization must preserve this device\'s transport authority');
    expect((await a.store.get(chapter.sourceId, chapter.chapterId))!.chapter.pages.single.pageId,
      locator, reason: 'the cloud fingerprint must not replace local page identity');
    await b.controller.synchronize();
    final received = (await b.store.get(chapter.sourceId, chapter.chapterId))!;
    expect(chapterRequiresSourceLocatorRefresh(received.chapter), isTrue);
    final gateway = ComicSourceResourceGateway(sourceForId: (_) => null);
    addTearDown(gateway.close);
    var forced = false;
    final composition = HomeReaderChapterComposition(
      ensureDurableServices: () async {},
      hydrateEntry: (entry, {required awaitCanonicalPhysicalBackfill}) async => entry,
      sourceResources: gateway, downloadComposition: () => null,
      requiresSourceLocatorRefresh: chapterRequiresSourceLocatorRefresh,
      refreshRemoteEntry: (entry, {required forceSourceRefresh}) async {
        forced = forceSourceRefresh;
        return ImportedLibraryEntry(chapter: chapter);
      },
      prepareVersionAuthority: (_) async => 1,
      trace: const NoopTraceSink(), monotonicMicros: () => 1);
    addTearDown(composition.close);
    final prepared = await composition.prepare(() async => received, refreshRemote: false);
    expect(forced, isTrue);
    expect(prepared.entry.chapter.pages.single.sourceId, locator);
    expect(prepared.responseSources.keys, [locator]);
    await b.controller.synchronize();
    await a.controller.synchronize();
    expect((await a.store.get(chapter.sourceId, chapter.chapterId))!.chapter.pages.single.sourceId, locator);
  });

  test('long page names and identities stay local while large libraries synchronize', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    final b = await _Device.create(dav);
    final opaque = List.filled(9000, 'x').join();
    final chapter = ImportedChapterRecord(directoryId: '/private/remote',
      displayName: 'Large chapter', sourceId: 'remote', comicId: 'comic',
      chapterId: 'large', sourceRevision: 'r1', pages: List.generate(2000, (i) =>
        ImportedPageRecord(displayName: '$opaque-$i', sourceId: 'https://example.test/$i',
          pageId: '$opaque-$i', contentKindHint: ContentKindHint.webp)));
    await a.store.upsertChapter(chapter);
    await a.controller.synchronize();
    expect(dav.payload!.length, lessThan(1024 * 1024),
      reason: 'page labels and logical identities must not repeat opaque resource payloads');
    final objects = dav.files.entries.where((entry) => entry.key.endsWith('.json.gz'));
    expect(objects, isNotEmpty);
    expect(objects.fold<int>(0, (sum, entry) => sum + entry.value.length), lessThan(1024 * 1024));
    expect(objects.every((entry) => entry.value[0] == 0x1f && entry.value[1] == 0x8b), isTrue);
    await b.controller.synchronize();
    final received = (await b.store.get('remote', 'large'))!.chapter;
    expect(received.pages.length, chapter.pages.length);
    expect(chapterRequiresSourceLocatorRefresh(received), isTrue);
    expect(librarySyncPageIdentity(received.pages.first),
      librarySyncPageIdentity(chapter.pages.first));
    expect(received.pages.first.displayName, '1');
    expect((await a.store.get('remote', 'large'))!.chapter.pages.first.pageId,
      chapter.pages.first.pageId);
    final stable = dav.payload;
    await b.controller.synchronize();
    await a.controller.synchronize();
    expect(jsonDecode(utf8.decode(dav.payload!)), jsonDecode(utf8.decode(stable!)));
  });

  test('older logical page metadata normalizes without a perpetual pending change', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    await a.controller.synchronize();
    final records = decodeLibrarySync(dav.payload!);
    final key = 'chapter:remote\u0000chapter';
    final original = records[key]!;
    final legacy = Map<String, Object?>.from(original.data!);
    legacy['pages'] = [for (var i = 0; i < 3; i++) <String, Object?>{
      'displayName': 'old descriptive name $i', 'pageId': '$i',
      'sourceId': importedChapterSummaryPageSourcePrefix + i.toString(),
      'contentKindHint': ContentKindHint.png.name,
    }];
    records[key] = LibrarySyncRecord(key: key, time: original.time + 1,
      writer: 'legacy', data: legacy);
    await dav.replace(encodeLibrarySync(records));
    await a.controller.synchronize();
    expect(a.controller.lastResult!.pending, 0);
    final normalized = decodeLibrarySync(dav.payload!)[key]!;
    expect(normalized.time, original.time + 1);
    expect(normalized.writer, 'legacy');
    expect((normalized.data!['pages'] as List).first['displayName'], '1');
    expect((await a.store.get('remote', 'chapter'))!.chapter.pages.first.pageId, '0');
    final stable = dav.payload;
    await a.controller.synchronize();
    expect(jsonDecode(utf8.decode(dav.payload!)), jsonDecode(utf8.decode(stable!)));
  });

  test('dated snapshots preserve legacy and old objects while no-op sync only reads latest', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    var now = DateTime.utc(2026, 10, 26, 1);
    final a = await _Device.create(dav, now: () => now);
    await a.seed();
    final legacy = encodeLibrarySync({});
    await dav.replace(legacy);
    await a.controller.synchronize();
    final firstHead = List<int>.of(dav.files[dav.config.latest.path]!);
    final firstFiles = Map<String, List<int>>.from(dav.files);
    expect(firstFiles.keys.where((key) => key == '/dav/zic/backups/2026-10-26.json'), hasLength(1));
    expect(dav.files[dav.config.file.path], legacy);
    dav.paths.clear();
    await a.controller.synchronize();
    expect(dav.dataPaths, ['GET ' + dav.config.latest.path]);
    expect(a.controller.message, contains('无分片需要上传'));
    await a.controller.synchronize();
    expect(dav.files[dav.config.latest.path], firstHead);
    now = now.add(const Duration(days: 1));
    await a.store.saveProgress(_progress(1, now));
    dav.paths.clear();
    await a.controller.synchronize();
    expect(dav.files.keys.where((key) => key == '/dav/zic/backups/2026-10-27.json'), hasLength(1));
    final objectWrites = dav.paths.where((path) => path.startsWith('PUT ') && path.endsWith('.json.gz'));
    expect(objectWrites, hasLength(1), reason: 'progress edits must not upload catalog/settings again');
    for (final entry in firstFiles.entries.where((entry) => entry.key != dav.config.latest.path &&
        !entry.key.endsWith('/repository.json'))) {
      expect(dav.files[entry.key], entry.value, reason: 'old backups and the old format are immutable');
    }
    expect(dav.methods, isNot(contains('DELETE')));
    await a.restart();
    dav.paths.clear();
    await a.controller.synchronize();
    expect(dav.dataPaths.every((path) => path.startsWith('GET ') || path.startsWith('HEAD ')), isTrue);
    expect(dav.paths.any((path) => path.startsWith('PROPFIND ') && path.contains('/backups/')), isFalse);
    expect(dav.paths.any((path) => path.endsWith('/library-v1.json')), isFalse);
  });

  test('a new device reads the committed latest snapshot and never remerges archived history', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    await a.controller.synchronize();
    await a.store.removeCategory('favorites');
    await a.controller.synchronize();
    // A partial or future-dated archive is not a committed head.
    dav.files['/dav/zic/backups/2099-01-01/20990101T000000000000Z-0000000000000000.json'] = [0];
    final b = await _Device.create(dav);
    dav.paths.clear();
    await b.controller.synchronize();
    expect(await b.store.listCategories(), isEmpty);
    expect((await b.store.getComicPreference('remote', 'comic'))!.categoryIds, isEmpty);
    expect(dav.dataPaths.every((path) => path.startsWith('GET ') || path.startsWith('HEAD ')), isTrue);
    expect(dav.paths.any((path) => path.startsWith('PROPFIND ') && path.contains('/backups/')), isFalse);
    expect(dav.methods, isNot(contains('DELETE')));
  });

  test('a failed shard upload leaves the current head and every older backup intact', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    await a.controller.synchronize();
    final before = Map<String, List<int>>.from(dav.files);
    await a.store.saveProgress(_progress(1, DateTime.now().toUtc()));
    dav.intercept = (request) async {
      if (request.method != 'PUT' || !request.uri.path.endsWith('.json.gz')) return false;
      await request.drain<void>();
      request.response.statusCode = 403;
      return true;
    };
    await expectLater(a.controller.synchronize(), throwsA(isA<WebDavException>()));
    for (final entry in before.entries) {
      expect(dav.files[entry.key], entry.value);
    }
    expect(dav.files.length, before.length);
    dav.intercept = null;
    await a.controller.synchronize();
    expect(ReadingProgress.fromJson(decodeLibrarySync(dav.payload!)
      ['progress:remote\u0000chapter']!.data!).pageIndex, 1);
  });

  test('an unchanged head retires cached objects from a failed publication', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    await a.controller.synchronize();
    await a.controller.synchronize();
    await a.store.saveProgress(_progress(1, DateTime.now().toUtc()));
    dav.intercept = (request) async {
      if (request.method != 'PUT' || request.uri.path != dav.config.latest.path) return false;
      await request.drain<void>();
      request.response.statusCode = 403;
      return true;
    };
    await expectLater(a.controller.synchronize(), throwsA(isA<WebDavException>()));
    final object = dav.paths.lastWhere((path) => path.startsWith('PUT ') && path.endsWith('.json.gz'));
    dav.intercept = null;
    dav.paths.clear();
    await a.controller.synchronize();
    expect(dav.paths, contains(object), reason: 'uncommitted bodies must not accumulate across 304 reads');
    expect(dav.paths, contains('GET ' + object.substring(4)));
    expect(a.controller.lastResult!.pending, 0);
  });

  test('lost immutable-object acknowledgement verifies the existing gzip before publishing', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    final faults = _HttpFaults(failAfterResponse: true, failMethod: 'PUT', failPath: '.json.gz');
    await HttpOverrides.runWithHttpOverrides(a.controller.synchronize, faults);
    expect(dav.headMethods, ['GET', 'GET', 'PUT']);
    final objectWrites = dav.paths.where((path) => path.startsWith('PUT ') && path.endsWith('.json.gz')).toList();
    final first = objectWrites.first.substring(4);
    expect(objectWrites.where((path) => path == 'PUT ' + first), hasLength(2));
    expect(dav.paths, contains('GET ' + first));
    expect(a.controller.lastResult!.pending, 0);
  });

  test('corrupt or missing latest shards never fall back to an older backup or apply locally', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    await a.controller.synchronize();
    final object = dav.files.entries.firstWhere((entry) => entry.key.endsWith('.json.gz'));
    final original = object.value;
    final b = await _Device.create(dav);
    dav.files[object.key] = original.toList()..[original.length - 1] ^= 1;
    dav.paths.clear();
    await expectLater(b.controller.synchronize(), throwsA(isA<LibrarySyncFormatException>()));
    expect(await b.store.listSavedComics(), isEmpty);
    expect(dav.dataPaths.every((path) => path.startsWith('GET ')), isTrue);
    dav.files.remove(object.key);
    await expectLater(b.controller.synchronize(), throwsA(isA<WebDavException>()));
    expect(await b.store.listCategories(), isEmpty);
    dav.files[object.key] = original;
    await b.controller.synchronize();
    expect(b.controller.lastResult!.pending, 0);
  });

  test('index validation rejects traversal and cached size lies before apply or publish', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    await a.controller.synchronize();
    await a.controller.synchronize();
    final original = dav.files[dav.config.latest.path]!;
    for (final traversal in [true, false]) {
      final index = jsonDecode(utf8.decode(original)) as Map;
      final part = (index['parts'] as List).first as Map;
      if (traversal) {
        part['hash'] = '../../private';
      } else {
        part['expandedBytes'] = 1;
      }
      dav._put(dav.config.latest.path, utf8.encode(jsonEncode(index)));
      dav.paths.clear();
      await expectLater(a.controller.synchronize(), throwsA(isA<LibrarySyncFormatException>()));
      expect(dav.dataPaths, ['GET ' + dav.config.latest.path]);
    }
  });

  test('a migrated device never falls back to the old library after latest disappears', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    await dav.replace(encodeLibrarySync({}));
    final a = await _Device.create(dav);
    await a.seed();
    await a.controller.synchronize();
    expect(a.files['state.json']!['remoteProtocol'], 3);
    await a.restart();
    dav.files.remove(dav.config.latest.path);
    dav.paths.clear();
    await expectLater(a.controller.synchronize(), throwsA(isA<WebDavException>()
      .having((e) => e.message, 'missing head', contains('最新同步索引缺失'))));
    expect(dav.dataPaths, ['GET ' + dav.config.latest.path]);
    expect((await a.store.listSavedComics()).single.comicId, 'comic');
  });

  test('daily backups are shared by devices and do not multiply after edits', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    final b = await _Device.create(dav);
    await a.seed();
    await a.controller.synchronize();
    final first = dav.files.entries.singleWhere((entry) => entry.key.contains('/backups/'));
    final original = List<int>.of(first.value);
    await b.controller.synchronize();
    await b.store.saveProgress(_progress(1, DateTime.now().toUtc().add(const Duration(seconds: 1))));
    await b.controller.synchronize();
    await a.controller.synchronize();
    expect(dav.files.keys.where((path) => path.contains('/backups/')), hasLength(1));
    expect(dav.files[first.key], original);
    expect(dav.paths.where((path) => path == 'PUT ' + first.key), hasLength(1));
    expect((await a.store.get('remote', 'chapter'))!.progress!.pageIndex, 1);
  });

  test('simultaneous devices merge while sharing one daily backup and releasing their own sessions', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    final b = await _Device.create(dav);
    await a.seed();
    await b.store.upsertCategory(LibraryCategory(categoryId: 'other', name: 'Other',
      sortOrder: 1, createdAt: DateTime.utc(2026)));
    await Future.wait([a.controller.synchronize(), b.controller.synchronize()]);
    await a.controller.synchronize();
    await b.controller.synchronize();
    expect((await a.store.listCategories()).map((c) => c.categoryId), containsAll(['favorites', 'other']));
    expect((await b.store.listCategories()).map((c) => c.categoryId), containsAll(['favorites', 'other']));
    expect(dav.files.keys.where((path) => path.contains('/backups/')), hasLength(1));
    final state = jsonDecode(utf8.decode(dav.files['/dav/zic/repository.json']!)) as Map;
    expect(state['sessions'], isEmpty);
  });

  test('an uncertain session write is confirmed without blindly replaying its CAS', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    final faults = _HttpFaults(failAfterResponse: true, failMethod: 'PUT', failPath: '/repository.json');
    await HttpOverrides.runWithHttpOverrides(a.controller.synchronize, faults);
    expect(dav.paths.where((path) => path == 'PUT /dav/zic/repository.json'), hasLength(2),
      reason: 'one registration and one release; lost acknowledgement is read back');
    expect(dav.headMethods.where((method) => method == 'PUT'), hasLength(1));
    expect(a.controller.lastResult!.pending, 0);
  });

  test('a failed daily backup preserves the committed sync and retries independently', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    dav.intercept = (request) async {
      if (request.method != 'PUT' || !request.uri.path.contains('/backups/')) return false;
      await request.drain<void>();
      request.response.statusCode = 403;
      return true;
    };
    await a.controller.synchronize();
    expect(a.controller.lastResult!.pending, 0);
    expect(a.controller.message, contains('同步完成'));
    expect(a.controller.message, contains('整理未完成'));
    expect(decodeLibrarySync(dav.payload!), contains('comic:remote\u0000comic'));
    dav.intercept = null;
    dav.paths.clear();
    await a.controller.synchronize();
    expect(dav.paths, isNot(contains('PUT ' + dav.config.latest.path)));
    expect(dav.files.keys.where((path) => path.contains('/backups/')), hasLength(1));
    expect(a.controller.message, isNot(contains('未完成')));
  });

  test('retention selects one snapshot per period with a repository-wide bound', () {
    final now = DateTime.utc(2026, 10, 26, 12);
    final paths = List.generate(800, (i) => 'backups/' +
      now.subtract(Duration(days: i)).toIso8601String().substring(0, 10) + '.json');
    final keep = selectWebDavBackups(paths, now);
    expect(keep.length, lessThanOrEqualTo(23));
    expect(keep, containsAll(paths.take(7)));
    expect(keep, isNot(contains(paths.last)));
    expect(selectWebDavBackups(paths.reversed, now), keep);
    final future = 'backups/2026-10-27.json';
    expect(selectWebDavBackups([...paths, future], DateTime.utc(2026, 10, 26, 23)),
      containsAll([future, ...paths.take(7)]), reason: 'UTC future dates do not consume normal retention slots');
    expect(() => selectWebDavBackups(['backups/2026-02-31.json'], now),
      throwsA(isA<WebDavException>()));
    final mixed = [for (var i = 0; i < paths.length; i++)
      i.isEven ? paths[i] : paths[i].replaceFirst('backups/', 'backups-v3/'),
      paths.first.replaceFirst('backups/', 'backups-v3/')];
    final mixedKeep = selectWebDavBackups(mixed, now);
    expect(mixedKeep.length, lessThanOrEqualTo(23));
    expect(mixedKeep.map((path) => path.substring(path.lastIndexOf('/') + 1)).toSet(),
      keep.map((path) => path.substring(path.lastIndexOf('/') + 1)).toSet());
    expect(mixedKeep, contains(paths.first));
    expect(mixedKeep, isNot(contains(paths.first.replaceFirst('backups/', 'backups-v3/'))));
  });

  test('maintenance protects roots across both directory layouts before collecting', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    await a.controller.synchronize();
    final fixture = _seedOldCloud(dav);
    final oldRetained = fixture.retained.replaceFirst('/objects/', '/objects-v3/');
    final oldOrphan = fixture.orphan.replaceFirst('/objects/', '/objects-v3/');
    dav._put(oldRetained, dav.files.remove(fixture.retained)!);
    dav._put(oldOrphan, dav.files.remove(fixture.orphan)!);
    final oldBackups = dav.files.entries.where((entry) => entry.key.contains('/backups/') &&
      entry.key != '/dav/zic/backups/' + dav.now.toIso8601String().substring(0, 10) + '.json').toList();
    for (var i = 0; i < oldBackups.length; i++) {
      final entry = oldBackups[i];
      final path = i.isEven ? entry.key : entry.key.replaceFirst('/backups/', '/backups-v3/');
      final index = jsonDecode(utf8.decode(entry.value)) as Map;
      index['snapshot'] = path.substring('/dav/zic/'.length);
      index['parts'] = [for (final raw in index['parts'] as List)
        {...raw as Map, 'object': (raw['object'] as String).replaceFirst('objects/', 'objects-v3/')}];
      dav.files.remove(entry.key);
      dav._put(path, utf8.encode(jsonEncode(index)));
    }
    await a.controller.synchronize();
    expect(a.controller.message, isNot(contains('未完成')));
    expect(dav.files[oldRetained], isNotNull);
    expect(dav.files[oldOrphan], isNull);
    expect(dav.files.keys.where((path) => RegExp(r'/backups(?:-v3)?/\d{4}-\d{2}-\d{2}\.json$').hasMatch(path)).length,
      lessThanOrEqualTo(23));
  });

  test('old v2 snapshots migrate without deleting or changing their files', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    final values = await prepareLibrarySyncValues(
      await readLibrarySyncSnapshot(a.store), a.preferences.readSyncReadingSettings(),
      a.preferences.syncReadingTimes);
    final records = values.map((key, value) => MapEntry(key, LibrarySyncRecord(
      key: key, time: value.initialTime, writer: 'previous', data: value.data)));
    await dav.replace(encodeLibrarySync(records), forceV2: true);
    final old = Map<String, List<int>>.from(dav.files)..remove(dav.config.latest.path);
    await a.controller.synchronize();
    for (final entry in old.entries) { expect(dav.files[entry.key], entry.value); }
    final index = jsonDecode(utf8.decode(dav.files[dav.config.latest.path]!)) as Map;
    expect(index['format'], webDavSnapshotFormat);
    expect((index['parts'] as List).every((part) => (part['object'] as String).startsWith('objects/')), isTrue);
    expect(dav.methods, isNot(contains('DELETE')));
  });

  test('maintenance keeps current and retained roots while reclaiming old orphan objects', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    await a.controller.synchronize();
    final fixture = _seedOldCloud(dav);
    final before = dav.etag;
    await a.controller.synchronize();
    expect(dav.etag, isNot(before), reason: 'maintenance fences pre-existing publishers');
    expect(dav.files.keys.where((path) => path.contains('/backups/')).length, lessThanOrEqualTo(23));
    expect(dav.files[fixture.orphan], isNull);
    expect(dav.files[fixture.retained], isNotNull);
    expect(dav.files['/dav/zic/objects/legacy.json.gz'], [1, 2, 3]);
    expect(dav.files['/dav/zic/objects/unknown.txt'], [4]);
    expect(a.controller.message, isNot(contains('未完成')));
    final client = WebDavClient(NetLane(maxActive: 1));
    addTearDown(client.close);
    final stale = await client.request(dav.config, 'PUT', dav.config.latest,
      headers: {'If-Match': before}, bytes: dav.files[dav.config.latest.path]!);
    expect(stale.status, 412);
    dav.paths.clear();
    await a.store.saveProgress(_progress(1, DateTime.now().toUtc().add(const Duration(seconds: 1))));
    await a.controller.synchronize();
    expect(dav.paths.any((path) => path.startsWith('PROPFIND ')), isFalse,
      reason: 'successful cleanup is scheduled weekly');
    expect(dav.paths.where((path) => path.startsWith('PUT ') && path.endsWith('.json.gz')).length,
      greaterThan(1), reason: 'the first edit after maintenance migrates catalog into the new epoch');
  });

  test('a live session on another device prevents repository maintenance', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    await a.controller.synchronize();
    final fixture = _seedOldCloud(dav);
    final client = WebDavClient(NetLane(maxActive: 2));
    addTearDown(client.close);
    final session = await WebDavRepositorySession.open(client, dav.config,
      checkActive: () {}, onRetry: (_) {});
    await a.controller.synchronize();
    expect(dav.files[fixture.orphan], isNotNull);
    expect(dav.methods, isNot(contains('DELETE')));
    await session.close();
    await a.controller.synchronize();
    expect(dav.files[fixture.orphan], isNull);
  });

  test('a lost session acknowledgement expires without blocking later synchronization', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    await a.controller.synchronize();
    final uri = dav.config.collection.resolve('repository.json');
    final state = jsonDecode(utf8.decode(dav.files[uri.path]!)) as Map;
    final expired = webDavGeneration(dav.now.subtract(const Duration(days: 1)));
    state['sessions'] = {expired: dav.now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch};
    state['maintenance'] = expired;
    dav._put(uri.path, utf8.encode(jsonEncode(state)));
    await a.controller.synchronize();
    final actual = jsonDecode(utf8.decode(dav.files[uri.path]!)) as Map;
    expect(actual['sessions'], isEmpty);
    expect(actual['maintenance'], isNull);
    expect(a.controller.lastResult!.pending, 0);
  });

  test('an incomplete or escaped listing never authorizes cloud deletion', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    await a.controller.synchronize();
    final fixture = _seedOldCloud(dav);
    for (final scenario in ['escaped', 'missing', 'incomplete']) {
      final path = '/dav/zic/repository.json';
      final state = jsonDecode(utf8.decode(dav.files[path]!)) as Map;
      state['maintenanceAfter'] = 0;
      dav._put(path, utf8.encode(jsonEncode(state)));
      dav.intercept = (request) async {
        if (request.method != 'PROPFIND' || request.headers.value('Depth') != '1') return false;
        request.response.statusCode = scenario == 'missing' ? 404 : 207;
        request.response.write('<d:multistatus xmlns:d="DAV:"><d:response><d:href>'
          '${scenario == 'escaped' ? 'https://other.test/escape' : request.uri.path}'
          '</d:href></d:response></d:multistatus>');
        return true;
      };
      await a.controller.synchronize();
      expect(a.controller.message, contains('整理未完成'));
      expect(dav.methods, isNot(contains('DELETE')), reason: scenario);
      expect(dav.files[fixture.orphan], isNotNull);
      expect(a.controller.lastResult!.pending, 0);
    }
  });

  test('a changed backup validator stops collection before shared objects are deleted', () async {
    final dav = await _Dav.start();
    addTearDown(dav.close);
    final a = await _Device.create(dav);
    await a.seed();
    await a.controller.synchronize();
    final fixture = _seedOldCloud(dav);
    var conflicted = false;
    dav.intercept = (request) async {
      if (!conflicted && request.method == 'DELETE' && request.uri.path.contains('/backups/')) {
        conflicted = true;
        dav._put(request.uri.path, dav.files[request.uri.path]!);
      }
      return false;
    };
    await a.controller.synchronize();
    expect(conflicted, isTrue);
    expect(a.controller.message, contains('整理未完成'));
    expect(dav.files[fixture.orphan], isNotNull);
    expect(dav.paths.any((path) => path.startsWith('DELETE ') && path.contains('/objects/')), isFalse);
  });
}

({String orphan, String retained}) _seedOldCloud(_Dav dav) {
  final generation = webDavGeneration(dav.now.subtract(const Duration(days: 90)));
  final latest = jsonDecode(utf8.decode(dav.files[dav.config.latest.path]!)) as Map;
  final part = Map<String, Object?>.from((latest['parts'] as List).first as Map);
  final bytes = dav.files[dav.config.collection.resolve(part['object']! as String).path]!;
  final retained = dav.config.collection.resolve('objects/$generation/${part['hash']}.json.gz').path;
  dav._put(retained, bytes);
  final orphan = dav.config.collection.resolve('objects/$generation/${'0' * 64}.json.gz').path;
  dav._put(orphan, [9]);
  for (var i = 1; i <= 500; i++) {
    final date = dav.now.subtract(Duration(days: i)).toIso8601String().substring(0, 10);
    final path = 'backups/$date.json';
    dav._put(dav.config.collection.resolve(path).path, utf8.encode(jsonEncode({
      ...latest, 'snapshot': path, 'createdAt': date + 'T00:00:00Z',
      'parts': [{...part, 'object': 'objects/$generation/${part['hash']}.json.gz'}],
    })));
  }
  dav._put('/dav/zic/objects/legacy.json.gz', [1, 2, 3]);
  dav._put('/dav/zic/objects/unknown.txt', [4]);
  final coordination = dav.config.collection.resolve('repository.json').path;
  final state = jsonDecode(utf8.decode(dav.files[coordination]!)) as Map;
  state['maintenanceAfter'] = 0;
  dav._put(coordination, utf8.encode(jsonEncode(state)));
  return (orphan: orphan, retained: retained);
}

ReadingProgress _progress(int page, DateTime time) => ReadingProgress(
  sourceId: 'remote', comicId: 'comic', chapterId: 'chapter', pageIndex: page,
  subPageOffset: .25, readerMode: ReaderMode.continuous, updatedAt: time);

final class _HttpFaults extends HttpOverrides {
  _HttpFaults({this.failures = const [], this.failAfterResponse = false,
    this.failMethod, this.failPath, this.afterResponse});
  final List<Object> failures;
  final bool failAfterResponse;
  final String? failMethod;
  final String? failPath;
  final Future<void> Function()? afterResponse;
  bool responseFailed = false;
  int opens = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FaultHttpClient(super.createHttpClient(context), this);
}

final class _FaultHttpClient implements HttpClient {
  _FaultHttpClient(this.delegate, this.faults);
  final HttpClient delegate;
  final _HttpFaults faults;
  @override
  set connectionTimeout(Duration? value) => delegate.connectionTimeout = value;
  @override
  void close({bool force = false}) => delegate.close(force: force);
  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) async {
    final index = faults.opens++;
    if (index < faults.failures.length) throw faults.failures[index];
    final request = await delegate.openUrl(method, uri);
    if (faults.failAfterResponse && !faults.responseFailed &&
        (faults.failMethod == null || method == faults.failMethod) &&
        (faults.failPath == null || uri.path.endsWith(faults.failPath!))) {
      faults.responseFailed = true;
      return _FaultHttpRequest(request, faults.afterResponse);
    }
    return request;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FaultHttpRequest implements HttpClientRequest {
  _FaultHttpRequest(this.delegate, this.afterResponse);
  final HttpClientRequest delegate;
  final Future<void> Function()? afterResponse;
  @override
  HttpHeaders get headers => delegate.headers;
  @override
  set followRedirects(bool value) => delegate.followRedirects = value;
  @override
  set contentLength(int value) => delegate.contentLength = value;
  @override
  void add(List<int> data) => delegate.add(data);
  @override
  Future<HttpClientResponse> close() async {
    await (await delegate.close()).drain<void>();
    await afterResponse?.call();
    throw const HandshakeException('Connection terminated during handshake');
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Device {
  _Device(this.dav, this.now);
  final _Dav dav;
  final DateTime Function()? now;
  final store = MemoryImportedLibraryStore();
  final preferences = AppPreferencesController();
  final files = <String, Map<String, Object?>>{};
  late WebDavSyncController controller;
  PortableSettingsOwner? portableSettings;
  ComicTranslationSettings? translation;
  Directory? translationDirectory;
  var policy = const WholeComicQueuePolicy();
  static Future<_Device> create(_Dav dav, {DateTime Function()? now, bool portable = false}) async {
    if (now != null) dav.clock = now;
    final device = _Device(dav, now);
    await device.store.open();
    if (portable) {
      device.translationDirectory = await Directory.systemTemp.createTemp('zic-webdav-settings-');
      device.translation = ComicTranslationSettings();
      await device.translation!.init(device.translationDirectory!.path);
      device.portableSettings = PortableSettingsOwner(preferences: device.preferences,
        loadTranslation: () async => device.translation!, sources: () async => [],
        readPluginState: () async => device.files['plugins'],
        writePluginState: (data) async => device.files['plugins'] = data,
        readDownloadPolicy: () => device.policy,
        updateDownloadPolicy: (value) async => device.policy = value);
    }
    device._createController();
    await device.controller.saveConfiguration(dav.config);
    addTearDown(() async {
      await device.controller.close();
      device.controller.dispose();
      device.preferences.dispose();
      await device.store.close();
      device.translation?.dispose();
      await device.translationDirectory?.delete(recursive: true);
    });
    return device;
  }
  void _createController() {
    controller = WebDavSyncController(client: WebDavClient(NetLane(maxActive: 2)),
      preferences: preferences, portableSettings: portableSettings,
      storageRoot: () async => '/unused', now: now,
      read: (name) async => files[name],
      write: (name, data) async {
        files[name] = Map<String, Object?>.from(jsonDecode(jsonEncode(data)) as Map);
      },
      readLibrary: () => readLibrarySyncSnapshot(store),
      applyLibrary: (records, expected) => applyLibrarySyncRecords(store, records, expected));
  }
  Future<void> restart() async {
    await controller.close();
    controller.dispose();
    _createController();
    await controller.initialize();
  }
  Future<void> seed() async {
    final time = DateTime.utc(2026, 1, 1);
    await store.upsertSavedComic(SavedComicRecord(sourceId: 'remote', comicId: 'comic',
      title: 'Comic', savedAt: time, updatedAt: time));
    await store.upsertChapter(ImportedChapterRecord(directoryId: '/private/remote',
      displayName: 'Chapter', sourceId: 'remote', comicId: 'comic', chapterId: 'chapter',
      sourceRevision: '1', importedAt: time, pages: List.generate(3, (i) => ImportedPageRecord(
        displayName: '$i.png', sourceId: 'https://example.test/$i.png',
        pageId: '$i', contentKindHint: ContentKindHint.png))));
    await store.saveProgress(_progress(2, time));
    await store.upsertCategory(LibraryCategory(categoryId: 'favorites', name: 'Favorites',
      sortOrder: 0, createdAt: time));
    await store.saveComicPreference(ComicPreference.defaults(sourceId: 'remote', comicId: 'comic',
      sourceKind: ComicSourceKind.remote).copyWith(liked: true,
        categoryIds: ['favorites'], updatedAt: time));
    await store.saveChapterReadState(ChapterReadState(sourceId: 'remote', comicId: 'comic',
      chapterId: 'chapter', isRead: true, updatedAt: time));
  }
}

final class _Dav {
  _Dav(this.server);
  final HttpServer server;
  final files = <String, List<int>>{};
  final versions = <String, int>{};
  int version = 0;
  int conflicts = 0;
  int? putStatus;
  bool weakEtag = false;
  bool collection = false;
  DateTime Function()? clock;
  DateTime get now => clock?.call().toUtc() ?? DateTime.now().toUtc();
  final directories = <String>{};
  String? previousEtag;
  final methods = <String>[];
  final headMethods = <String>[];
  final paths = <String>[];
  List<String> get dataPaths => paths.where((path) => !path.endsWith('/repository.json')).toList();
  final conditions = <String?>[];
  Future<void> Function()? beforePut;
  Future<void> Function()? beforeGet;
  Future<void> Function(HttpRequest)? hold;
  Future<bool> Function(HttpRequest)? intercept;
  WebDavConfig get config => WebDavConfig(
    address: 'http://127.0.0.1:${server.port}/dav/', username: 'dummy', password: 'dummy-secret');
  String _etag(String path) => '"v${versions[path] ?? 0}"';
  String get etag => _etag(config.latest.path);
  List<int>? get payload {
    final head = files[config.latest.path];
    if (head == null) return files[config.file.path];
    final index = jsonDecode(utf8.decode(head)) as Map;
    final records = <String, LibrarySyncRecord>{};
    for (final part in index['parts'] as List) {
      final bytes = files[config.collection.resolve(part['object'] as String? ??
        'objects/${part['hash']}.json.gz').path]!;
      records.addAll(decodeLibrarySync(const MetadataGzipCodec().decode(bytes,
        maxBytes: part['expandedBytes'] as int)));
    }
    return encodeLibrarySync(records, compress: false);
  }
  static Future<_Dav> start() async {
    final dav = _Dav(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    dav.server.listen((request) async {
      try { await dav._handle(request); } on Object { /* cancelled socket */ }
    });
    return dav;
  }
  void _put(String path, List<int> bytes) {
    files[path] = bytes;
    versions[path] = ++version;
    var parent = path.substring(0, path.lastIndexOf('/') + 1);
    while (parent.length > 1) {
      directories.add(parent);
      parent = parent.substring(0, parent.length - 1);
      parent = parent.substring(0, parent.lastIndexOf('/') + 1);
    }
  }
  Future<void> replace(List<int> bytes, {bool forceV2 = false}) async {
    if (!forceV2 && !files.containsKey(config.latest.path)) {
      _put(config.file.path, bytes);
      return;
    }
    final prepared = await prepareWebDavSnapshot({}, decodeLibrarySync(bytes), forceParts: true);
    for (final part in prepared.parts) {
      _put(config.collection.resolve('objects/' + part.hash + '.json.gz').path, part.bytes);
    }
    final snapshot = 'backups/2026-01-01/20260101T000000000000Z-' +
        version.toRadixString(16).padLeft(16, '0') + '.json';
    final index = utf8.encode(jsonEncode({
      'format': 'zic-library-sync-v2', 'snapshot': snapshot,
      'createdAt': DateTime.utc(2026).toIso8601String(),
      'parts': prepared.parts.map((part) => part.descriptor).toList(),
    }));
    _put(config.collection.resolve(snapshot).path, index);
    _put(config.latest.path, index);
  }
  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final isHead = path == config.latest.path;
    final isMutable = isHead || path == config.file.path;
    methods.add(request.method);
    paths.add(request.method + ' ' + path);
    request.response.headers.set(HttpHeaders.dateHeader, HttpDate.format(now));
    if (isHead) headMethods.add(request.method);
    expect(request.headers.value(HttpHeaders.authorizationHeader),
      'Basic ${base64Encode(utf8.encode('dummy:dummy-secret'))}');
    if (await intercept?.call(request) == true) {
      await request.response.close();
      return;
    }
    if (hold != null) {
      await hold!(request);
      await request.response.close();
      return;
    }
    switch (request.method) {
      case 'PROPFIND':
        request.response.statusCode = 207;
        if (request.headers.value('Depth') == '0') {
          request.response.write('<d:multistatus xmlns:d="DAV:"/>');
        } else {
          expect(request.headers.value('Depth'), '1');
          final children = <String>{
            path,
            ...files.keys.where((key) => key.startsWith(path) &&
              !key.substring(path.length).contains('/')),
            ...directories.where((key) => key.startsWith(path) && key != path &&
              !key.substring(path.length, key.length - 1).contains('/')),
          };
          request.response.write('<d:multistatus xmlns:d="DAV:">');
          for (final child in children) {
            request.response.write('<d:response><d:href>$child</d:href><d:propstat><d:prop>'
              '<d:getetag>${_etag(child)}</d:getetag><d:resourcetype>'
              '${child.endsWith('/') ? '<d:collection/>' : ''}'
              '</d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>');
          }
          request.response.write('</d:multistatus>');
        }
      case 'MKCOL':
        request.response.statusCode = collection ? 405 : 201;
        collection = true;
        directories.add(path);
      case 'HEAD':
        request.response.statusCode = files.containsKey(path) ? 200 : 404;
      case 'GET':
        if (isHead) await beforeGet?.call();
        final bytes = files[path];
        request.response.statusCode = bytes == null ? 404
            : request.headers.value('If-None-Match') == _etag(path) ? 304 : 200;
        if (bytes != null) {
          request.response.headers.set(HttpHeaders.etagHeader, (weakEtag ? 'W/' : '') + _etag(path));
          if (request.response.statusCode == 200) request.response.add(bytes);
        }
      case 'DELETE':
        if (!files.containsKey(path)) {
          request.response.statusCode = 404;
        } else if (request.headers.value('If-Match') != _etag(path)) {
          request.response.statusCode = 412;
        } else {
          files.remove(path);
          request.response.statusCode = 204;
        }
      case 'PUT':
        final bytes = await request.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
        if (path.endsWith('.json.gz')) {
          expect(request.headers.contentType!.mimeType, 'application/gzip');
          expect(bytes.take(2), [0x1f, 0x8b]);
        }
        if (isMutable) {
          conditions.add(request.headers.value('If-Match') ?? request.headers.value('If-None-Match'));
          await beforePut?.call();
          previousEtag = _etag(path);
        }
        if (isMutable && putStatus != null) {
          request.response.statusCode = putStatus!;
        } else if ((!files.containsKey(path) && request.headers.value('If-None-Match') == '*') ||
            (files.containsKey(path) && request.headers.value('If-Match') == _etag(path))) {
          _put(path, bytes);
          request.response.statusCode = 201;
        } else {
          if (isMutable) conflicts++;
          request.response.statusCode = 412;
        }
      default:
        request.response.statusCode = 405;
    }
    await request.response.close();
  }
  Future<void> close() async => server.close(force: true);
}

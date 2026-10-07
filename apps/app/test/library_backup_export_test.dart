import 'dart:convert';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart' show MethodCall, MethodChannel, PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/library_backup.dart';

final class _Store extends Fake
    implements ImportedLibraryStore, ImportedLibraryBackupSnapshotStore {
  var snapshots = 0;

  @override
  Future<ImportedLibraryBackupSnapshot> readLibraryBackupSnapshot() async {
    snapshots++;
    return ImportedLibraryBackupSnapshot(
      entries: <ImportedLibraryEntry>[],
      savedComics: <SavedComicRecord>[],
      categories: <LibraryCategory>[],
      comicPreferences: <ComicPreference>[
        ComicPreference.defaults(sourceId: 'source', comicId: 'comic')
            .copyWith(acknowledgedVersionComicId: 'known-successor'),
      ],
      chapterReadStates: <ChapterReadState>[],
      sourcePreferences: <ComicSourcePreference>[],
      migrationIssues: <LibraryMigrationIssue>[],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.zic.zic/document_export');
  const unsupportedPicker = MethodChannel('plugins.flutter.io/file_selector');

  for (final result in <String>['saved', 'cancelled', 'failed']) {
    test('Android backup document export $result uses one snapshot', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final store = _Store();
      final calls = <MethodCall>[];
      var unsupportedPickerCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(unsupportedPicker, (_) async {
        unsupportedPickerCalls++;
        throw PlatformException(code: 'unsupported',
            message: 'getSavePath() has not been implemented.');
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance
          .defaultBinaryMessenger.setMockMethodCallHandler(unsupportedPicker, null));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        expect(call.method, 'saveDocument');
        final args = call.arguments as Map<Object?, Object?>;
        expect(args['mimeType'], 'application/json');
        expect(args['suggestedName'], matches(r'^zic-backup-.*\.json$'));
        final payload = jsonDecode(utf8.decode(args['bytes'] as Uint8List))
            as Map<String, Object?>;
        expect(payload['format'], 'zic-library-backup-v1');
        expect(payload['chapters'], isEmpty);
        expect(payload['chapterReadStates'], isEmpty);
        final prefs = payload['comicPreferences'] as List<Object?>;
        expect((prefs.single as Map<String, Object?>)['acknowledgedVersionComicId'],
            'known-successor');
        expect(payload.keys, containsAll(<String>[
          'savedComics', 'categories', 'comicPreferences',
          'sourcePreferences', 'migrationIssues',
        ]));
        if (result == 'failed') {
          throw PlatformException(code: 'document-write-failed');
        }
        return result == 'cancelled' ? null : 'content://fixture/backup.json';
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance
          .defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

      final export = exportImportedLibraryBackup(store);
      if (result == 'failed') {
        await expectLater(export, throwsA(isA<PlatformException>().having(
          (error) => error.code, 'code', 'document-write-failed',
        )));
      } else {
        expect(await export, result == 'cancelled'
            ? isNull : 'content://fixture/backup.json');
      }
      expect(store.snapshots, 1);
      expect(unsupportedPickerCalls, 0);
      expect(calls, hasLength(1), reason: 'no unsupported picker fallback/retry');
    });
  }
}

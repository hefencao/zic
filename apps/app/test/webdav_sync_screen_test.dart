import 'package:network_bridge/network_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sessions/sessions.dart';
import 'package:zic/app_preferences.dart';
import 'package:zic/library_data_scope.dart';
import 'package:zic/webdav_sync.dart';
import 'package:zic/webdav_sync_screen.dart';

void main() {
  testWidgets('manual sync form validates, conceals and persists credentials without reading library', (tester) async {
    final preferences = AppPreferencesController();
    final files = <String, Map<String, Object?>>{};
    var reads = 0;
    final controller = WebDavSyncController(client: WebDavClient(NetLane(maxActive: 1)),
      preferences: preferences, storageRoot: () async => '/unused',
      read: (name) async => files[name],
      write: (name, value) async => files[name] = value,
      readLibrary: () async { reads++; throw StateError('unexpected library read'); },
      applyLibrary: (_, _) async => fail('unexpected library mutation'));
    addTearDown(() {
      controller.dispose();
      preferences.dispose();
    });
    await tester.pumpWidget(MaterialApp(home: WebDavSyncScreen(controller: controller)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(webDavSaveKey));
    await tester.tap(find.byKey(webDavSaveKey));
    await tester.pumpAndSettle();
    expect(find.text('请填写有效的 HTTP/HTTPS WebDAV 目录地址'), findsOneWidget);
    await tester.enterText(find.byKey(webDavAddressKey), 'https://example.test/dav');
    await tester.enterText(find.byKey(webDavUsernameKey), 'user');
    await tester.enterText(find.byKey(webDavPasswordKey), 'secret');
    expect(tester.widget<TextField>(find.descendant(of: find.byKey(webDavPasswordKey),
      matching: find.byType(TextField))).obscureText, isTrue);
    await tester.ensureVisible(find.text('同步数据'));
    await tester.tap(find.text('同步数据'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('library-data-history')), 200,
      scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const ValueKey('library-data-history')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(webDavSaveKey), 200,
      scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(webDavSaveKey));
    await tester.pumpAndSettle();
    expect(controller.config!.base.toString(), 'https://example.test/dav/');
    expect(files['connection.json']!['password'], 'secret');
    expect(controller.sections, isNot(contains(LibraryDataSection.history)));
    expect(files['connection.json']!['sections'], isNot(contains('history')));
    expect(reads, 0, reason: 'opening and saving the page must not load the library or start sync');
    await tester.scrollUntilVisible(find.byKey(webDavDisconnectKey), 200,
      scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(webDavDisconnectKey));
    await tester.pumpAndSettle();
    expect(controller.config, isNull);
    expect(files['connection.json']!.containsKey('password'), isFalse);
    final closing = controller.close();
    await tester.pump();
    await closing;
  });
}

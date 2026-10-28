import 'package:catalog/catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/app_preferences.dart';
import 'package:zic/extension_repositories.dart';
import 'package:zic/extension_repository_management_screen.dart';

void main() {
  testWidgets('repository edits preserve enablement and distinguish indexes on a shared host', (tester) async {
    final preferences = AppPreferencesController();
    addTearDown(preferences.dispose);
    final original = ExtensionRepository(format: ExternalComicPluginFormat.veneraJavaScript,
      index: Uri.https('raw.githubusercontent.com', '/alice/catalog/main/index.json'),
      enabled: false, name: '旧名');
    preferences.setExtensionRepository(original);
    preferences.setExtensionRepository(original.copyWith(name: '', enabled: true,
      index: Uri.https('raw.githubusercontent.com', '/alice/catalog/beta/index.json')));
    var selectionChanges = 0;
    await tester.pumpWidget(MaterialApp(home: ExtensionRepositoryManagementScreen(
      format: original.format, preferences: preferences,
      onSelectionChanged: () => selectionChanges++)));
    expect(find.text('alice/catalog'), findsOneWidget);
    expect(find.textContaining('main/index.json'), findsOneWidget);
    expect(find.textContaining('beta/index.json'), findsOneWidget);
    expect(find.text(original.index.toString()), findsNothing);
    await tester.tap(find.text('旧名'));
    await tester.pumpAndSettle();
    final name = find.byWidgetPredicate((widget) => widget is TextField &&
      widget.decoration?.labelText == '仓库名称（可选）');
    final url = find.byWidgetPredicate((widget) => widget is TextField &&
      widget.decoration?.labelText == 'HTTPS 仓库索引');
    expect(tester.widget<TextField>(url).controller!.text, original.index.toString());
    await tester.enterText(name, '新名');
    final editedIndex = Uri.https('raw.githubusercontent.com', '/alice/catalog/test/index.json');
    await tester.enterText(url, editedIndex.toString());
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final edited = preferences.extensionRepositories.singleWhere((item) => item.index == editedIndex);
    expect(edited.name, '新名');
    expect(edited.enabled, isFalse);
    expect(preferences.extensionRepositoryRecords[original.identity], isNull);
    expect(selectionChanges, 0, reason: 'editing a disabled index does not reload the catalog');
    final tile = find.ancestor(of: find.text('新名'), matching: find.byType(ListTile));
    await tester.tap(find.descendant(of: tile, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    expect(selectionChanges, 1);
    expect(preferences.extensionRepositories.singleWhere((item) => item.index == editedIndex).name, '新名');
    await tester.tap(find.text('新名'));
    await tester.pumpAndSettle();
    await tester.enterText(name, '只改名称');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(selectionChanges, 1, reason: 'a name-only edit does not reload the catalog');
    await tester.tap(find.text('只改名称'));
    await tester.pumpAndSettle();
    await tester.enterText(name, '');
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('只改名称'), findsOneWidget);
    expect(selectionChanges, 1);
  });
}

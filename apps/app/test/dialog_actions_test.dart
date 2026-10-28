import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/dialog_actions.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('modal actions isolate page shapes and preserve semantics in ${brightness.name}', (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final colors = ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: brightness);
      var closes = 0;
      var deletes = 0;
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(colorScheme: colors, useMaterial3: true,
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(shape: const StadiumBorder())),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(shape: const StadiumBorder())),
          textButtonTheme: TextButtonThemeData(
            style: TextButton.styleFrom(shape: const StadiumBorder())),
        ),
        home: MediaQuery(data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: Scaffold(body: SingleChildScrollView(child: Column(children: [
            FilledButton(onPressed: () {}, child: const Text('页面操作')),
            AlertDialog(title: const Text('确认操作'), content: const Text('复用弹窗操作栏'), actions: [
              AppDialogActions(onClose: () => closes++, actions: [
                TextButton(onPressed: () {}, child: const Text('恢复自动')),
                OutlinedButton(onPressed: () {}, child: const Text('保留现有版本')),
                FilledButton(onPressed: () => deletes++,
                  style: FilledButton.styleFrom(backgroundColor: colors.error,
                    foregroundColor: colors.onError), child: const Text('删除')),
                const FilledButton(onPressed: null, child: Text('等待完成')),
              ]),
            ]),
          ])))),
      ));
      await tester.pumpAndSettle();
      Material materialFor(Finder button) => tester.widget<Material>(
        find.descendant(of: button, matching: find.byType(Material)).first);
      expect(materialFor(find.widgetWithText(FilledButton, '页面操作')).shape, isA<StadiumBorder>());
      for (final label in ['恢复自动', '保留现有版本', '删除', '等待完成']) {
        final button = find.ancestor(of: find.text(label), matching: find.byWidgetPredicate(
          (widget) => widget is TextButton || widget is OutlinedButton || widget is FilledButton));
        expect(materialFor(button).shape, isA<RoundedRectangleBorder>());
      }
      expect(materialFor(find.widgetWithText(FilledButton, '删除')).color, colors.error);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '等待完成')).onPressed, isNull);
      await tester.tap(find.byTooltip('关闭'));
      expect(closes, 1);
      expect(deletes, 0);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      expect(deletes, 1);
      expect(closes, 1);
      expect(tester.takeException(), isNull);
    });
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/operation_hint.dart';

void main() {
  for (final (gesture, movement, label) in const [
    (OperationHintGesture.swipeUp, Offset(0, -100), '向上滑动'),
    (OperationHintGesture.swipeDown, Offset(0, 100), '向下滑动'),
    (OperationHintGesture.swipeLeft, Offset(-100, 0), '向左滑动'),
    (OperationHintGesture.swipeRight, Offset(100, 0), '向右滑动'),
  ]) {
    testWidgets('hint accepts $gesture only from the highlighted target', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final target = GlobalKey();
        OperationHintResult? result;
        var targetTaps = 0;
        await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
          home: Builder(builder: (context) => Scaffold(body: Stack(children: [
            Center(child: TextButton(onPressed: () async {
              result = await showOperationHint(context: context, target: target,
                title: '手势提示', message: '从亮起的位置滑动。', gesture: gesture);
            }, child: const Text('提示'))),
            Align(alignment: Alignment.bottomCenter, child: SizedBox(key: target, width: 180, height: 60,
              child: TextButton(onPressed: () => targetTaps++, child: const Text('目标')))),
          ]))),
        ));
        await tester.tap(find.text('提示'));
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel(label), findsOneWidget);
        final center = tester.getCenter(find.byKey(target));
        await tester.tapAt(center);
        await tester.pumpAndSettle();
        expect(targetTaps, 0, reason: 'The spotlight must not accidentally activate underlying controls');
        await tester.dragFrom(const Offset(40, 150), movement);
        await tester.pumpAndSettle();
        expect(result, isNull);
        await tester.dragFrom(center, -movement);
        await tester.pumpAndSettle();
        expect(result, isNull);
        await tester.dragFrom(center, movement);
        await tester.pumpAndSettle();
        expect(result, OperationHintResult.performed);
        expect(find.byKey(operationHintDismissKey), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }

  testWidgets('animated hint can be dismissed and fits a small screen with large text', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final target = GlobalKey();
    OperationHintResult? result;
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.8)), child: child!),
      home: Builder(builder: (context) => Scaffold(body: Stack(children: [
        TextButton(onPressed: () async {
          result = await showOperationHint(context: context, target: target,
            title: '可复用操作提示', message: '从下方亮起的区域向上滑动，展开更多筛选条件。',
            gesture: OperationHintGesture.swipeUp);
        }, child: const Text('提示')),
        Align(alignment: Alignment.bottomCenter, child: SizedBox(key: target, height: 60, width: 300)),
      ]))),
    ));
    await tester.tap(find.text('提示'));
    await tester.pump();
    final before = tester.widget<Transform>(find.byKey(operationHintArrowKey)).transform.getTranslation().y;
    await tester.pump(const Duration(milliseconds: 500));
    final after = tester.widget<Transform>(find.byKey(operationHintArrowKey)).transform.getTranslation().y;
    expect(after, lessThan(before));
    await tester.binding.setSurfaceSize(const Size(320, 240));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(operationHintDismissKey));
    await tester.pumpAndSettle();
    expect(result, OperationHintResult.dismissed);
    expect(tester.takeException(), isNull);
  });
}

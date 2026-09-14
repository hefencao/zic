import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';
import 'package:reader_runtime/src/reader_transfer_progress_indicator.dart';

void main() {
  const networkKey = ValueKey<String>('network');
  const partialKey = ValueKey<String>('partial');

  testWidgets('known partial and connecting activity share one horizontal lane',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ReaderTransferProgressIndicator(
            progress: PipelineTransferProgress(
              active: true,
              partialBytes: 1_277_952,
              transportBytes: 0,
              totalBytes: 13_452_374,
              transportAttemptActive: false,
            ),
            networkKey: networkKey,
            partialKey: partialKey,
          ),
        ),
      ),
    );

    final activity = tester.widget<LinearProgressIndicator>(
      find.byKey(networkKey),
    );
    expect(activity.value, isNull);
    final networkSize = tester.getSize(find.byKey(networkKey));
    final partialSize = tester.getSize(find.byKey(partialKey));
    expect(
      partialSize.width / networkSize.width,
      closeTo(1_277_952 / 13_452_374, 0.002),
    );
    expect(
      tester.getCenter(find.byKey(networkKey)).dy,
      tester.getCenter(find.byKey(partialKey)).dy,
      reason: 'connecting activity and partial belong to one visual lane',
    );
    expect(
      tester.getSemantics(find.byType(ReaderTransferProgressIndicator)),
      matchesSemantics(
        label: '已有页面partial，正在连接页面资源',
        value: '已有partial 1277952/13452374 bytes；正在连接',
      ),
    );
  });

  testWidgets('prefix replay leaves only the local remainder after the wave',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ReaderTransferProgressIndicator(
            progress: PipelineTransferProgress(
              active: true,
              partialBytes: 12_329_700,
              transportBytes: 5_423_900,
              totalBytes: null,
              transportTotalBytes: 15_640_724,
              transportAttemptActive: true,
            ),
            networkKey: networkKey,
            partialKey: partialKey,
          ),
        ),
      ),
    );

    expect(find.byType(LinearProgressIndicator), findsNothing);
    final fullWidth = tester.getSize(find.byKey(networkKey)).width;
    final partialSize = tester.getSize(find.byKey(partialKey));
    final partialLeft = tester.getTopLeft(find.byKey(partialKey)).dx;
    expect(
      partialLeft / fullWidth,
      closeTo(5_423_900 / 15_640_724, 0.002),
      reason: 'the straight local segment begins where the wave currently ends',
    );
    expect(
      partialSize.width / fullWidth,
      closeTo((12_329_700 - 5_423_900) / 15_640_724, 0.002),
      reason: 'partial shows only the locally available remainder beyond transport',
    );
    expect(
      tester.getCenter(find.byKey(networkKey)).dy,
      tester.getCenter(find.byKey(partialKey)).dy,
    );
    expect(
      tester.getSemantics(find.byType(ReaderTransferProgressIndicator)),
      matchesSemantics(
        label: '已有页面partial，正在重读页面前缀',
        value: '已有partial 12329700/15640724 bytes；正在重读 5423900/12329700 bytes',
      ),
    );
  });

  testWidgets('transport at or beyond partial leaves no separate partial mark',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ReaderTransferProgressIndicator(
            progress: PipelineTransferProgress(
              active: true,
              partialBytes: 8 * 1024 * 1024,
              transportBytes: 9 * 1024 * 1024,
              totalBytes: 16 * 1024 * 1024,
              transportAttemptActive: true,
            ),
            networkKey: networkKey,
            partialKey: partialKey,
          ),
        ),
      ),
    );

    expect(find.byKey(networkKey), findsOneWidget);
    expect(find.byKey(partialKey), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('idle partial uses its real known fraction on the same lane',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ReaderTransferProgressIndicator(
            progress: PipelineTransferProgress(
              active: false,
              partialBytes: 64,
              transportBytes: 0,
              totalBytes: 128,
              transportAttemptActive: false,
            ),
            networkKey: networkKey,
            partialKey: partialKey,
          ),
        ),
      ),
    );

    final fullWidth = tester.getSize(find.byType(ReaderTransferProgressIndicator)).width;
    expect(tester.getSize(find.byKey(partialKey)).width / fullWidth, closeTo(0.5, 0.001));
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
      tester.getSemantics(find.byType(ReaderTransferProgressIndicator)),
      matchesSemantics(
        label: '已有页面partial',
        value: '已有partial 64/128 bytes',
      ),
    );
  });

  testWidgets('truly unknown total never invents a partial fraction',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ReaderTransferProgressIndicator(
            progress: PipelineTransferProgress(
              active: true,
              partialBytes: 8 * 1024 * 1024,
              transportBytes: 2 * 1024 * 1024,
              totalBytes: null,
              transportAttemptActive: true,
            ),
            networkKey: networkKey,
            partialKey: partialKey,
          ),
        ),
      ),
    );

    final activity = tester.widget<LinearProgressIndicator>(
      find.byKey(networkKey),
    );
    expect(activity.value, isNull);
    expect(find.byKey(partialKey), findsNothing,
        reason: 'without a scale we must not draw a fake width or dashed proxy');
    expect(
      tester.getSemantics(find.byType(ReaderTransferProgressIndicator)),
      matchesSemantics(
        label: '已有页面partial，正在重读页面前缀',
        value: '已有partial 8388608 bytes；正在重读 2097152/8388608 bytes',
      ),
    );
  });

  testWidgets('unknown total without partial remains network activity only',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ReaderTransferProgressIndicator(
            progress: PipelineTransferProgress(
              active: true,
              partialBytes: 0,
              transportBytes: 0,
              totalBytes: null,
              transportAttemptActive: false,
            ),
            networkKey: networkKey,
            partialKey: partialKey,
          ),
        ),
      ),
    );

    expect(find.byKey(networkKey), findsOneWidget);
    expect(find.byKey(partialKey), findsNothing);
    expect(
      tester.getSemantics(find.byType(ReaderTransferProgressIndicator)),
      matchesSemantics(label: '正在连接页面资源', value: '正在连接'),
    );
  });
}

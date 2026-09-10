import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';
import 'package:reader_runtime/src/reader_transfer_progress_indicator.dart';

void main() {
  const networkKey = ValueKey<String>('network');
  const partialKey = ValueKey<String>('partial');

  testWidgets('unknown total still exposes an existing physical partial',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ReaderTransferProgressIndicator(
            progress: PipelineTransferProgress(
              active: true,
              partialBytes: 8216280,
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
    expect(find.byKey(partialKey), findsOneWidget);
    expect(
      tester.getSemantics(find.byType(ReaderTransferProgressIndicator)),
      matchesSemantics(
        label: '已有页面partial，正在连接页面资源',
        value: '已有partial 8216280 bytes',
      ),
    );
  });

  testWidgets('unknown-total prefix replay shows determinate partial-relative progress',
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

    final indicator = tester.widget<LinearProgressIndicator>(
      find.byKey(networkKey),
    );
    expect(indicator.value, 0.25);
    expect(find.byKey(partialKey), findsOneWidget);
    expect(
      tester.getSemantics(find.byType(ReaderTransferProgressIndicator)),
      matchesSemantics(
        label: '正在重读已有页面前缀',
        value: '已有partial 8388608 bytes；重读 2097152/8388608 bytes',
      ),
    );
  });

  testWidgets('idle physical partial stays visible without network semantics',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ReaderTransferProgressIndicator(
            progress: PipelineTransferProgress(
              active: false,
              partialBytes: 64,
              transportBytes: 48,
              totalBytes: 128,
              transportAttemptActive: false,
            ),
            networkKey: networkKey,
            partialKey: partialKey,
          ),
        ),
      ),
    );

    expect(find.byKey(networkKey), findsOneWidget);
    expect(find.byKey(partialKey), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
      tester.getSemantics(find.byType(ReaderTransferProgressIndicator)),
      matchesSemantics(
        label: '已有页面partial',
        value: '已有partial 64/128 bytes',
      ),
    );
  });

  testWidgets('idle unknown-total partial stays visible without connecting state',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ReaderTransferProgressIndicator(
            progress: PipelineTransferProgress(
              active: false,
              partialBytes: 8216280,
              totalBytes: null,
            ),
            networkKey: networkKey,
            partialKey: partialKey,
          ),
        ),
      ),
    );

    expect(find.byKey(networkKey), findsOneWidget);
    expect(find.byKey(partialKey), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
      tester.getSemantics(find.byType(ReaderTransferProgressIndicator)),
      matchesSemantics(
        label: '已有页面partial',
        value: '已有partial 8216280 bytes',
      ),
    );
  });

  testWidgets('unknown total without partial stays network-only',
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
      matchesSemantics(label: '正在连接页面资源'),
    );
  });
}

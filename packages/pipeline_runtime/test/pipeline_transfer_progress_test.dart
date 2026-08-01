import 'package:flutter_test/flutter_test.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';

void main() {
  test('unknown-length transfer distinguishes connecting from receiving', () {
    const connecting = PipelineTransferProgress(
      active: true,
      existingBytes: 64,
      committedBytes: 64,
    );
    const receiving = PipelineTransferProgress(
      active: true,
      existingBytes: 64,
      committedBytes: 128,
    );

    expect(connecting.phase, PipelineTransferPhase.connecting);
    expect(connecting.receivedBytes, 0);
    expect(receiving.phase, PipelineTransferPhase.receiving);
    expect(receiving.receivedBytes, 64);
    expect(receiving.committedFraction, isNull);
  });
}

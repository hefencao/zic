import 'package:flutter_test/flutter_test.dart';
import 'package:zic/webp_demo.dart';

void main() {
  test('app composition owns the shared page network lane', () {
    expect(
      identical(
        defaultLocalMediaPipelineFactory.pageDownloadLane,
        defaultDownloadResourceCoordinator.networkLane,
      ),
      isTrue,
    );
    expect(defaultDownloadResourceCoordinator.networkLane.maxActive, 5);
    expect(
      defaultDownloadResourceCoordinator.networkLane.preemptionCandidateGrace,
      const Duration(milliseconds: 100),
    );
    expect(
      identical(
        defaultLocalMediaPipelineFactory.artifactReadScheduler,
        defaultDownloadResourceCoordinator.localReadScheduler,
      ),
      isTrue,
    );
  });
}

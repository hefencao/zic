import 'package:downloads/downloads.dart';
import 'package:pipeline_native/pipeline_native.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';

final _defaultNativeMediaRuntimeFactory = NativePipelineMediaRuntimeFactory();

final defaultDownloadResourceCoordinator = DownloadResourceCoordinator();

final defaultLocalMediaPipelineFactory = PipelineReaderSessionFactory(
  mediaRuntimeFactory: _defaultNativeMediaRuntimeFactory,
  artifactReadScheduler: defaultDownloadResourceCoordinator.localReadScheduler,
  speculativeEncodedReadBudget:
      defaultDownloadResourceCoordinator.speculativeEncodedReadBudget,
  pageDownloadLane: defaultDownloadResourceCoordinator.networkLane,
);

Future<void> prewarmDefaultLocalMediaPipeline() =>
    _defaultNativeMediaRuntimeFactory.prewarm();

Future<void> shutdownDefaultLocalMediaPipeline() async {
  await defaultLocalMediaPipelineFactory.disposeRetainedSessions();
  await defaultLocalMediaPipelineFactory.disposeTransferRuntimes();
  await _defaultNativeMediaRuntimeFactory.shutdownComposition();
}

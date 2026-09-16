import 'package:downloads/downloads.dart';
import 'package:local_media_ui/local_media_ui.dart';
import 'package:pipeline_native/pipeline_native.dart';

final _defaultNativeMediaRuntimeFactory = NativePipelineMediaRuntimeFactory();

final defaultDownloadResourceCoordinator = DownloadResourceCoordinator();

final defaultLocalMediaPipelineFactory = PipelineReaderSessionFactory(
  mediaRuntimeFactory: _defaultNativeMediaRuntimeFactory,
  artifactReadScheduler: defaultDownloadResourceCoordinator.localReadScheduler,
  speculativeEncodedReadBudget:
      defaultDownloadResourceCoordinator.speculativeEncodedReadBudget,
  pageDownloadLane: defaultDownloadResourceCoordinator.networkLane,
  externalPresentationPrewarmer: prewarmPipelineExternalStaticPresentation,
);

Future<void> prewarmDefaultLocalMediaPipeline() =>
    _defaultNativeMediaRuntimeFactory.prewarm();

Future<void> shutdownDefaultLocalMediaPipeline() async {
  await defaultLocalMediaPipelineFactory.disposeRetainedSessions();
  await defaultLocalMediaPipelineFactory.disposeTransferRuntimes();
  await _defaultNativeMediaRuntimeFactory.shutdownComposition();
}

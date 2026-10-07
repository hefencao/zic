import 'package:downloads/downloads.dart';
import 'package:local_media_ui/local_media_ui.dart';
import 'package:pipeline_native/pipeline_native.dart';

final _defaultNativeMediaRuntimeFactory = NativePipelineMediaRuntimeFactory();

final defaultDownloadResourceCoordinator = DownloadResourceCoordinator();

final defaultPipelineStaticPresentation =
    PipelineStaticPresentation(pipelinePresentationRasterCache);

final defaultLocalMediaPipelineFactory = PipelineReaderSessionFactory(
  mediaRuntimeFactory: _defaultNativeMediaRuntimeFactory,
  artifactReadScheduler: defaultDownloadResourceCoordinator.localReadScheduler,
  speculativeEncodedReadBudget:
      defaultDownloadResourceCoordinator.speculativeEncodedReadBudget,
  pageDownloadLane: defaultDownloadResourceCoordinator.networkLane,
  externalPresentationPrewarmer: defaultPipelineStaticPresentation.prewarm,
  presentationCacheAuthority: defaultPipelineStaticPresentation.cacheAuthority,
);

Future<void> prewarmDefaultLocalMediaPipeline() =>
    _defaultNativeMediaRuntimeFactory.prewarm();

/// Releases only idle Reader re-entry sessions. Active Reader leases remain
/// attached, so exclusive storage operations can distinguish a real mounted
/// Reader from the bounded two-minute re-entry pool.
Future<void> drainDefaultRetainedReaderSessions() =>
    defaultLocalMediaPipelineFactory.disposeRetainedSessions();

Future<void> shutdownDefaultLocalMediaPipeline() async {
  await defaultLocalMediaPipelineFactory.disposeRetainedSessions();
  await defaultLocalMediaPipelineFactory.disposeTransferRuntimes();
  await _defaultNativeMediaRuntimeFactory.shutdownComposition();
}

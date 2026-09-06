import 'package:downloads/downloads.dart';
import 'package:pipeline_native/pipeline_native.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';

// App composition for local media UI and Pipeline-owned native output.
export 'package:local_media_ui/local_media_ui.dart';

final _defaultNativeMediaRuntimeFactory = NativePipelineMediaRuntimeFactory();

final defaultDownloadResourceCoordinator = DownloadResourceCoordinator();

final defaultLocalMediaPipelineFactory = PipelineReaderSessionFactory(
  mediaRuntimeFactory: _defaultNativeMediaRuntimeFactory,
  artifactReadScheduler: defaultDownloadResourceCoordinator.localReadScheduler,
  pageDownloadLane: defaultDownloadResourceCoordinator.networkLane,
);

/// Forces the process-level native decode workers to start before page entry.
Future<void> prewarmDefaultLocalMediaPipeline() =>
    _defaultNativeMediaRuntimeFactory.prewarm();

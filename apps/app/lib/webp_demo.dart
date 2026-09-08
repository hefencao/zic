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

/// Forces the composition-retained native decode workers to start before page
/// entry. They survive normal Reader back/re-entry, but not an explicit App
/// composition shutdown.
Future<void> prewarmDefaultLocalMediaPipeline() =>
    _defaultNativeMediaRuntimeFactory.prewarm();

/// Closes every resource retained by the default local-media composition.
///
/// Normal Reader navigation must use the retention pool instead. This boundary
/// is only for whole-App teardown before Android destroys/replaces the current
/// FlutterEngine while keeping the Android application process alive.
Future<void> shutdownDefaultLocalMediaPipeline() async {
  await defaultLocalMediaPipelineFactory.disposeRetainedSessions();
  await defaultLocalMediaPipelineFactory.disposeTransferRuntimes();
  await _defaultNativeMediaRuntimeFactory.shutdownComposition();
}

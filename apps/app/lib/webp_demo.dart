import 'package:pipeline_native/pipeline_native.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';

// App composition for local media UI and Pipeline-owned native output.
export 'package:local_media_ui/local_media_ui.dart';

const defaultLocalMediaPipelineFactory = PipelineReaderSessionFactory(
  mediaRuntimeFactory: NativePipelineMediaRuntimeFactory(),
);

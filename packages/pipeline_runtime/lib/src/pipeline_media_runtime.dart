import 'package:domain/domain.dart';
import 'package:flutter/widgets.dart';
import 'package:media/media.dart';
import 'package:telemetry/telemetry.dart';

/// One atomically configured platform media runtime for a Reader session.
///
/// The upper composition layer supplies the factory. `pipeline_runtime` owns
/// each created runtime and closes it after decode/upload/output users drain.
abstract interface class PipelineMediaRuntimeFactory {
  PipelineMediaRuntime create({
    required String sessionId,
    required MonoClock clock,
    required TraceSink traceSink,
  });
}

abstract interface class PipelineMediaRuntime {
  SourceFactory get sources;
  CursorFactory get cursors;
  FrameUploader get uploader;
  PipelineOutputProjector get outputs;
  RendererKind get renderer;

  Future<void> close();
}

/// Converts a Pipeline-owned output frame to an opaque Presentation surface.
///
/// Implementations may retain platform implementation details internally, but
/// the surface API never exposes a texture id, native pointer or mutable frame.
abstract interface class PipelineOutputProjector {
  PipelinePageSurface project(OutputFrame frame);
}

/// Read-only visual surface consumed by Reader Presentation.
///
/// The Pipeline output claim owns the underlying frame lifetime. Calling
/// [build] only creates a view over that already-presented output.
abstract interface class PipelinePageSurface {
  int get width;
  int get height;

  Widget build({
    Key? key,
    BoxFit fit = BoxFit.contain,
    FilterQuality filterQuality = FilterQuality.low,
  });
}

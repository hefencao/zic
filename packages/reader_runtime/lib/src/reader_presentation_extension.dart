import 'dart:async';

import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';

/// Optional presentation consumer. Media, transport and demand remain in Pipeline.
abstract class ReaderPresentationExtension extends ChangeNotifier {
  void observe(ReaderObs observation);
  Widget decoratePage(BuildContext context, PageAsset asset, BoxFit fit, Widget child);
  Widget buildControls(BuildContext context);
  Widget buildStatus(BuildContext context) => const SizedBox.shrink();
  bool handleSingleTap(Offset globalPosition) => false;
  Future<void> close();
}

typedef ReaderPresentationExtensionFactory = ReaderPresentationExtension Function(
  PipelineReaderSession pipeline,
);

/// Owns the extension lifetime alongside, but independently of, the media lease.
final class ReaderPresentationExtensionHost extends StatefulWidget {
  const ReaderPresentationExtensionHost({
    required this.pipeline,
    required this.factory,
    required this.builder,
    super.key,
  });

  final PipelineReaderSession pipeline;
  final ReaderPresentationExtensionFactory? factory;
  final Widget Function(ReaderPresentationExtension? extension) builder;

  @override
  State<ReaderPresentationExtensionHost> createState() =>
      _ReaderPresentationExtensionHostState();
}

final class _ReaderPresentationExtensionHostState
    extends State<ReaderPresentationExtensionHost> {
  ReaderPresentationExtension? _extension;

  @override
  void initState() {
    super.initState();
    _extension = widget.factory?.call(widget.pipeline);
  }

  @override
  void didUpdateWidget(covariant ReaderPresentationExtensionHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.pipeline, widget.pipeline)) {
      unawaited(_extension?.close());
      _extension = widget.factory?.call(widget.pipeline);
    }
  }

  @override
  void dispose() {
    unawaited(_extension?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_extension);
}

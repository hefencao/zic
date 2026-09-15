import 'package:domain/domain.dart';
import 'package:flutter/widgets.dart';
import 'package:telemetry/telemetry.dart';

import 'pipeline_reader_session.dart';

typedef PipelineReaderSessionBuilder = Widget Function(
  BuildContext context,
  PipelineReaderSession session,
);

/// Composition owner for one pipeline session.
///
/// Reader widgets consume the already-created session and only report viewport
/// observations. Network/download/decode/upload ownership and disposal remain
/// in the pipeline layer even when the Reader subtree is rebuilt.
final class PipelineReaderSessionHost extends StatefulWidget {
  const PipelineReaderSessionHost({
    required this.chapter,
    required this.factory,
    required this.builder,
    this.traceSink,
    super.key,
  });

  final ChapterManifest chapter;
  final PipelineReaderSessionFactory factory;
  final TraceSink? traceSink;
  final PipelineReaderSessionBuilder builder;

  @override
  State<PipelineReaderSessionHost> createState() =>
      _PipelineReaderSessionHostState();
}

final class _PipelineReaderSessionHostState
    extends State<PipelineReaderSessionHost> {
  static int _sequence = 0;
  late final PipelineReaderSessionFactory _ownerFactory;
  late final PipelineReaderSession _session;

  @override
  void initState() {
    super.initState();
    _ownerFactory = widget.factory;
    _session = _ownerFactory.acquire(
      chapter: widget.chapter,
      sessionId: 'pipeline-reader-${++_sequence}',
      traceSink: widget.traceSink,
    );
  }

  @override
  void didUpdateWidget(covariant PipelineReaderSessionHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameChapter(oldWidget.chapter, widget.chapter)) {
      throw StateError(
        'PipelineReaderSessionHost chapter identity is immutable; replace the '
        'widget key to open another chapter or source revision',
      );
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _session);

  @override
  void dispose() {
    _ownerFactory.release(_session);
    super.dispose();
  }
}

bool _sameChapter(ChapterManifest left, ChapterManifest right) {
  if (left.sourceId != right.sourceId ||
      left.comicId != right.comicId ||
      left.chapter.chapterId != right.chapter.chapterId ||
      left.chapter.sourceRevision != right.chapter.sourceRevision ||
      left.readingDirection != right.readingDirection ||
      left.pages.length != right.pages.length) {
    return false;
  }
  for (var index = 0; index < left.pages.length; index++) {
    final a = left.pages[index];
    final b = right.pages[index];
    if (a.pageId != b.pageId ||
        a.index != b.index ||
        a.uri != b.uri ||
        a.width != b.width ||
        a.height != b.height ||
        a.byteLength != b.byteLength ||
        a.contentKindHint != b.contentKindHint ||
        a.animatedHint != b.animatedHint ||
        a.checksum != b.checksum ||
        a.checksumAlgorithm != b.checksumAlgorithm) {
      return false;
    }
  }
  return true;
}

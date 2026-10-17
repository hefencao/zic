import 'package:comic_translation/comic_translation.dart';
import 'package:flutter/material.dart';

/// Read-only presentation of the current page's translation stages.
final class ComicTranslationIndicator extends StatelessWidget {
  const ComicTranslationIndicator({super.key, required this.pageIndex,
    required this.phase, required this.status, this.onlyWhileProcessing = false,
    this.showPageNumber = false});

  final int pageIndex;
  final ComicTranslationPhase? phase;
  final String status;
  final bool onlyWhileProcessing;
  final bool showPageNumber;

  @override
  Widget build(BuildContext context) {
    final preparing = phase == ComicTranslationPhase.waitingForImage ||
        phase == ComicTranslationPhase.queued || phase == ComicTranslationPhase.loadingCache;
    final recognizing = phase == ComicTranslationPhase.recognizing;
    final translating = phase == ComicTranslationPhase.translating;
    final ready = phase == ComicTranslationPhase.ready;
    if (onlyWhileProcessing && !preparing && !recognizing && !translating) {
      return const SizedBox.shrink();
    }
    final problem = phase == ComicTranslationPhase.failed ||
        phase == ComicTranslationPhase.unavailable || phase == ComicTranslationPhase.unsupportedMedia;
    final working = preparing || recognizing || translating;
    final icon = recognizing ? Icons.document_scanner_outlined : translating ? Icons.translate
        : ready ? Icons.check : problem ? Icons.error_outline : Icons.hourglass_empty;
    final stage = recognizing ? 'ocr' : translating ? 'translation' : 'preparing';
    return Semantics(liveRegion: true, label: showPageNumber ? '第${pageIndex + 1}页，$status' : status,
      child: ExcludeSemantics(child: Container(
        key: const ValueKey('reader-translation-status'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.76),
          borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (showPageNumber) ...[
            Text('${pageIndex + 1}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(width: 6),
          ],
          SizedBox.square(dimension: 28, child: Stack(alignment: Alignment.center, children: [
            Icon(icon, size: 18,
              color: ready ? Colors.lightGreenAccent : problem ? Colors.amberAccent : Colors.white),
            if (working) SizedBox.square(dimension: 26, child: CircularProgressIndicator(
              key: ValueKey('reader-translation-$stage-progress'), strokeWidth: 1.5, color: Colors.white)),
          ])),
        ]),
      )),
    );
  }
}

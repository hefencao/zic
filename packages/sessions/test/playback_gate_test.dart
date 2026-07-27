import 'package:domain/domain.dart';
import 'package:pipeline/pipeline.dart';
import 'package:sessions/sessions.dart';
import 'package:test/test.dart';

void main() {
  test('overlap freezes both pages and dominant resumes only its page', () {
    final gate = PlaybackGate();
    final current = _id('current');
    final target = _id('target');
    final calls = <String>[];
    bool freeze(DecodeId id) {
      calls.add('freeze:${id.download.content.pageId}');
      return true;
    }

    bool resume(DecodeId id) {
      calls.add('resume:${id.download.content.pageId}');
      return true;
    }

    gate.apply(
      viewport: const ViewportState(
        phase: ViewportPhase.overlap,
        currentPageIndex: 0,
        targetPageIndex: 1,
        dominantPageIndex: null,
      ),
      ids: <int, DecodeId>{0: current, 1: target},
      freeze: freeze,
      resume: resume,
    );
    expect(calls, <String>['freeze:current', 'freeze:target']);

    calls.clear();
    gate.apply(
      viewport: const ViewportState(
        phase: ViewportPhase.dominant,
        currentPageIndex: 0,
        targetPageIndex: 1,
        dominantPageIndex: 1,
      ),
      ids: <int, DecodeId>{0: current, 1: target},
      freeze: freeze,
      resume: resume,
    );
    expect(calls, <String>['resume:target']);
  });

  test('page leaving the viewport is frozen before it is forgotten', () {
    final gate = PlaybackGate();
    final current = _id('current');
    final target = _id('target');
    final calls = <String>[];
    bool freeze(DecodeId id) {
      calls.add('freeze:${id.download.content.pageId}');
      return true;
    }

    bool resume(DecodeId id) {
      calls.add('resume:${id.download.content.pageId}');
      return true;
    }

    gate.apply(
      viewport: const ViewportState(
        phase: ViewportPhase.dominant,
        currentPageIndex: 0,
        targetPageIndex: 1,
        dominantPageIndex: 1,
      ),
      ids: <int, DecodeId>{0: current, 1: target},
      freeze: freeze,
      resume: resume,
    );
    calls.clear();

    gate.apply(
      viewport: const ViewportState(
        phase: ViewportPhase.idle,
        currentPageIndex: 1,
        dominantPageIndex: 1,
      ),
      ids: <int, DecodeId>{1: target},
      freeze: freeze,
      resume: resume,
    );
    expect(calls, isEmpty);
    expect(gate.states.keys, contains(target));
    expect(gate.states.keys, isNot(contains(current)));
  });
}

DecodeId _id(String page) {
  final download = DownloadId(
    content: ContentId(
      sourceId: 'source',
      comicId: 'comic',
      chapterId: 'chapter',
      pageId: page,
    ),
    sourceRevision: 'r1',
    canonicalUri: Uri.parse('https://example.test/$page.webp'),
  );
  return DecodeId(
    download: download,
    physicalWidth: 8,
    physicalHeight: 8,
    pixelFormat: PixelFormat.rgba8888,
    renderer: RendererKind.flutterImage,
  );
}

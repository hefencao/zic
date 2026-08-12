import 'package:sessions/sessions.dart';
import 'package:test/test.dart';

void main() {
  test('counts complete ANMF chunks across arbitrary fragment boundaries', () {
    final bytes = _animatedWebp(<int>[3, 5, 4]);
    final tracker = WebpFramePrefixTracker();

    for (var offset = 0; offset < bytes.length; offset += 5) {
      final end = (offset + 5).clamp(0, bytes.length).toInt();
      tracker.add(bytes.sublist(offset, end));
    }

    expect(tracker.unsupported, isFalse);
    expect(tracker.completedFrames, 3);
    expect(tracker.bytesConsumed, bytes.length);
  });

  test('partial ANMF is not counted until its complete payload arrives', () {
    final bytes = _animatedWebp(<int>[20]);
    final tracker = WebpFramePrefixTracker();
    final frameChunkStart = 12;
    final incomplete = frameChunkStart + 8 + 19;

    tracker.add(bytes.sublist(0, incomplete));
    expect(tracker.completedFrames, 0);
    tracker.add(bytes.sublist(incomplete));
    expect(tracker.completedFrames, 1);
  });

  test('non-WebP prefix disables flow counting instead of blocking forever', () {
    final tracker = WebpFramePrefixTracker();
    tracker.add(List<int>.generate(32, (index) => index));
    expect(tracker.unsupported, isTrue);
    expect(tracker.completedFrames, 0);
  });
}

List<int> _animatedWebp(List<int> payloadSizes) {
  final chunks = <int>[];
  for (final size in payloadSizes) {
    chunks
      ..addAll('ANMF'.codeUnits)
      ..addAll(_u32(size))
      ..addAll(List<int>.generate(size, (index) => index & 0xff));
    if (size.isOdd) chunks.add(0);
  }
  final riffSize = 4 + chunks.length;
  return <int>[
    ...'RIFF'.codeUnits,
    ..._u32(riffSize),
    ...'WEBP'.codeUnits,
    ...chunks,
  ];
}

List<int> _u32(int value) => <int>[
      value & 0xff,
      (value >> 8) & 0xff,
      (value >> 16) & 0xff,
      (value >> 24) & 0xff,
    ];

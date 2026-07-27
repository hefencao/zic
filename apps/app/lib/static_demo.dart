import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reader/reader.dart';
import 'package:sessions/sessions.dart';
import 'package:telemetry/telemetry.dart';
import 'package:pipeline/src/heuristic_policy.dart';

final class StaticDemoScreen extends StatefulWidget {
  const StaticDemoScreen({super.key});

  @override
  State<StaticDemoScreen> createState() => _StaticDemoScreenState();
}

final class _StaticDemoScreenState extends State<StaticDemoScreen> {
  late final Future<ChapterManifest> _chapter;

  @override
  void initState() {
    super.initState();
    final source = LocalManifestSource(
      sourceId: 'local-demo',
      loader: rootBundle.loadString,
      comicManifestPaths: const <String, String>{
        'zic-demo': 'assets/demo/comic.json',
      },
      chapterManifestPaths: const <String, String>{
        'chapter-001': 'assets/demo/chapter_001.json',
      },
    );
    _chapter = source.loadChapter('chapter-001');
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ChapterManifest>(
      future: _chapter,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(title: const Text('100 页静态章节')),
            body: Center(child: Text('加载演示失败：${snapshot.error}')),
          );
        }
        if (!snapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return _ReaderRuntime(chapter: snapshot.requireData);
      },
    );
  }
}

final class _ReaderRuntime extends StatefulWidget {
  const _ReaderRuntime({required this.chapter});

  final ChapterManifest chapter;

  @override
  State<_ReaderRuntime> createState() => _ReaderRuntimeState();
}

final class _ReaderRuntimeState extends State<_ReaderRuntime> {
  late final MonoClock _clock;
  late final MemoryTraceSink _memoryTrace;
  late final TraceSink _trace;
  late final FakeCoordinator _coordinator;
  late final ReaderBinding _binding;
  late final ReaderController _reader;

  @override
  void initState() {
    super.initState();
    _clock = SystemClock();
    _memoryTrace = MemoryTraceSink();
    _trace = MultiTraceSink(<TraceSink>[
      _memoryTrace,
      CallbackTraceSink((event) => debugPrint(event.toJsonLine())),
    ]);
    _coordinator = FakeCoordinator(clock: _clock, traceSink: _trace);
    _binding = ReaderBinding(
      chapter: widget.chapter,
      decodeTarget: DecodeTarget(
        physicalWidth: 1080,
        physicalHeight: 1920,
      ),
      clock: _clock,
      traceSink: _trace,
      coordinator: _coordinator,
      playback: _coordinator,
    );
    _reader = ReaderController(
      sessionId: 'demo-session',
      chapter: widget.chapter,
      onObservation: _binding.accept,
      clock: _clock,
      traceSink: _trace,
    );
  }

  @override
  void dispose() {
    _reader.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.chapter.chapter.title),
        actions: <Widget>[
          PopupMenuButton<ReadingDirection>(
            tooltip: '阅读方向',
            initialValue: _reader.direction,
            onSelected: _reader.setDirection,
            itemBuilder: (context) => const <PopupMenuEntry<ReadingDirection>>[
              PopupMenuItem(value: ReadingDirection.ltr, child: Text('LTR')),
              PopupMenuItem(value: ReadingDirection.rtl, child: Text('RTL')),
              PopupMenuItem(
                value: ReadingDirection.vertical,
                child: Text('纵向'),
              ),
            ],
            icon: const Icon(Icons.swap_horiz),
          ),
        ],
      ),
      body: ReaderView(
        controller: _reader,
        clock: _clock,
        traceSink: _trace,
      ),
    );
  }
}

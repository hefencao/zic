import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:domain/domain.dart';
import 'package:zic_library/library.dart';
import 'package:pipeline/pipeline.dart';
import 'package:reader/reader.dart';
import 'package:sessions/sessions.dart';
import 'package:telemetry/telemetry.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const App());
}

final class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'zic',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.dark,
      home: const _DemoReaderLoader(),
    );
  }
}

final class _DemoReaderLoader extends StatefulWidget {
  const _DemoReaderLoader();

  @override
  State<_DemoReaderLoader> createState() => _DemoReaderLoaderState();
}

final class _DemoReaderLoaderState extends State<_DemoReaderLoader> {
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
            body: Center(child: Text('Failed to load demo: ${snapshot.error}')),
          );
        }
        if (!snapshot.hasData) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
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
  late final FakeSessionCoordinator _coordinator;
  late final PipelineController _pipeline;
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
    _coordinator = FakeSessionCoordinator(
      clock: _clock,
      traceSink: _trace,
    );
    _pipeline = PipelineController(
      chapter: widget.chapter,
      decodeTarget: DecodeTarget(
        physicalWidth: 1080,
        physicalHeight: 1920,
      ),
      clock: _clock,
      traceSink: _trace,
      onUpdate: (update) => _coordinator.reconcile('demo-session', update),
    );
    _reader = ReaderController(
      sessionId: 'demo-session',
      chapter: widget.chapter,
      onObservation: _pipeline.accept,
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
        title: Text('zic · ${widget.chapter.chapter.title}'),
        actions: <Widget>[
          PopupMenuButton<ReadingDirection>(
            tooltip: 'Reading direction',
            initialValue: _reader.direction,
            onSelected: _reader.setDirection,
            itemBuilder: (context) => const <PopupMenuEntry<ReadingDirection>>[
              PopupMenuItem(value: ReadingDirection.ltr, child: Text('LTR')),
              PopupMenuItem(value: ReadingDirection.rtl, child: Text('RTL')),
              PopupMenuItem(
                value: ReadingDirection.vertical,
                child: Text('Vertical'),
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

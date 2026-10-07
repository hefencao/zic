import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_media_ui/local_media_ui.dart';
import 'package:pipeline_native/pipeline_native.dart';
import 'package:reader_runtime/reader_runtime.dart';
import 'package:telemetry/telemetry.dart';
import 'package:zic/startup_platform.dart';

// Separate device entry. Only temporary inputs are opened. The messenger
// observes the original production messages and returns their original Future.
final _clock = Stopwatch()..start();
final _calls = <Map<String, Object?>>[];
final _cases = <Map<String, Object?>>[];
final _trace = MemoryTraceSink();
late String _output;
PipelineReaderSession? _mountedSession;
int _reads = 0;

final class _AcceptanceBinding extends WidgetsFlutterBinding {
  @override
  BinaryMessenger createBinaryMessenger() =>
      _ObservedMessenger(super.createBinaryMessenger());
}

final class _ObservedMessenger implements BinaryMessenger {
  _ObservedMessenger(this.delegate);
  final BinaryMessenger delegate;
  static const codec = StandardMethodCodec();

  @override
  Future<ByteData?>? send(String channel, ByteData? message) {
    if (channel != 'dev.zic/texture' || message == null) {
      return delegate.send(channel, message);
    }
    final call = codec.decodeMethodCall(message);
    final args = call.arguments is Map ? call.arguments as Map : const <Object?, Object?>{};
    final row = <String, Object?>{
      'method': call.method, 'start_us': _clock.elapsedMicroseconds,
      'texture_id': args['textureId'], 'frame_index': args['frameIndex'],
    };
    _calls.add(row);
    final response = delegate.send(channel, message);
    // Do not replace messages/replies, delay the channel, or add a gate.
    response?.then<void>((reply) {
      row['reply_us'] = _clock.elapsedMicroseconds;
      try {
        if (reply == null) throw StateError('null platform reply');
        final decoded = codec.decodeEnvelope(reply);
        if (call.method == 'create') row['texture_id'] = (decoded as Map)['textureId'];
        row['success'] = true;
      } on PlatformException catch (error) {
        row['success'] = false;
        row['error_code'] = error.code;
      } on Object catch (error) {
        row['success'] = false;
        row['observer_error'] = error.toString();
      }
    }, onError: (Object error, StackTrace stack) {
      row['reply_us'] = _clock.elapsedMicroseconds;
      row['success'] = false;
      row['transport_error'] = error.toString();
    });
    return response;
  }

  @override
  void setMessageHandler(String channel, MessageHandler? handler) =>
      delegate.setMessageHandler(channel, handler);

  @override
  Future<void> handlePlatformMessage(String channel, ByteData? data,
      ui.PlatformMessageResponseCallback? callback) =>
      // ignore: deprecated_member_use
      delegate.handlePlatformMessage(channel, data, callback);
}

Future<void> main() async {
  _AcceptanceBinding();
  _status('Texture 重入验收');
  await waitForFirstFlutterUiDisplayed();
  for (final plugin in <String>['texture_bridge', 'reader_runtime']) {
    await attachAndroidPlugin(plugin);
  }
  final support = await getStartupApplicationSupportPath();
  _require(support != null, 'application support path missing');
  _output = '$support/zic-reader-used-texture-results.json';
  final media = NativePipelineMediaRuntimeFactory();
  final coordinator = DownloadResourceCoordinator();
  final raster = PipelinePresentationRasterCache();
  final presentation = PipelineStaticPresentation(raster);
  final factory = PipelineReaderSessionFactory(
    mediaRuntimeFactory: media, pageDownloadLane: coordinator.networkLane,
    artifactReadScheduler: coordinator.localReadScheduler,
    speculativeEncodedReadBudget: coordinator.speculativeEncodedReadBudget,
    bytesLoader: (asset, control) async {
      _reads++;
      return File.fromUri(asset.uri).readAsBytes();
    },
    externalPresentationPrewarmer: presentation.prewarm,
    presentationCacheAuthority: presentation.cacheAuthority,
  );
  var passed = false;
  try {
    final allUsed = <int>{};
    for (final kind in <String>['static', 'animated']) {
      final input = File('$support/zic-reader-used-texture-inputs/$kind.webp');
      _require(await input.exists(), 'staged $kind WebP missing');
      final record = ImportedChapterRecord(
        directoryId: 'texture-fixture:$kind', displayName: 'Texture $kind',
        sourceId: 'local-folder', comicId: 'texture-fixture',
        chapterId: kind, sourceRevision: 'texture-r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(displayName: '$kind.webp', sourceId: input.uri.toString(),
            pageId: 'page-0', mediaFormat: 'webp', contentKindHint: ContentKindHint.webp),
        ],
      );
      final chapter = record.toManifest();
      PipelineReaderSession? original;
      for (var entry = 0; entry < 3; entry++) {
        final begin = _clock.elapsedMicroseconds;
        final beforeReads = _reads;
        final beforeTrace = _trace.events.length;
        final first = Completer<void>();
        _mountedSession = null;
        runApp(MaterialApp(key: UniqueKey(), home: PipelineReaderSessionHost(
          chapter: chapter, factory: factory, traceSink: _trace,
          builder: (context, pipeline) {
            _mountedSession = pipeline;
            return ReaderRuntimeScreen(chapter: chapter, pipeline: pipeline,
              artifactPageBuilder: (context, asset, reportFirstFrame, runtime) =>
                LocalImagePlayer(
                  key: ValueKey<String>(asset.assetKey),
                  image: PickedImage(file: XFile(asset.uri.toString()),
                    format: LocalImageFormat.webp, displayName: asset.pageId,
                    sourceId: asset.uri.toString(), byteLength: asset.byteLength),
                  presentationBytesLoader: (_, token) => runtime.loadPresentationBytes(token),
                  pageStream: runtime.pageStream, pageOutput: runtime.pageOutput,
                  staticPresentation: presentation,
                  onPlaybackCapabilityChanged: runtime.reportPlaybackCapability,
                  onDimensionsChanged: (size) => runtime.reportDimensions(
                    size.width.round(), size.height.round()),
                  onFirstFrame: () {
                    reportFirstFrame();
                    if (!first.isCompleted) first.complete();
                  },
                  traceClock: runtime.clock, traceSink: runtime.traceSink,
                  traceSessionId: runtime.sessionId, demandRevision: runtime.demandRevision,
                  downloadIdentity: runtime.pageStream.identity,
                  playback: runtime.playback, fit: runtime.mediaFit,
                ),
            );
          },
        )));
        await first.future.timeout(const Duration(seconds: 30));
        await Future<void>.delayed(Duration(seconds: kind == 'animated' ? 3 : 1));
        final session = _mountedSession!;
        if (entry == 0) original = session;
        _require(identical(session, original), 'warm reentry did not retain the exact session');
        final textures = _textures();
        _require(textures.length == 1, 'actual Reader does not mount exactly one Texture');
        final texture = textures.single;
        _require(allUsed.add(texture), 'used SurfaceProducer reused across Reader routes');
        final creates = _calls.where((r) => r['method'] == 'create' &&
          r['texture_id'] == texture && r['success'] == true).toList();
        final presents = _calls.where((r) => r['method'] == 'present' &&
          r['texture_id'] == texture && r['success'] == true).toList();
        _require(creates.length == 1 && presents.isNotEmpty,
          'mounted Texture lacks actual platform create/present replies');
        final events = _trace.events.skip(beforeTrace).toList();
        final timings = events.where((e) => e.kind == TraceEventKind.framePipelineTiming).toList();
        _require(timings.isNotEmpty && timings.every((e) =>
          e.payload['renderer'] == 'androidTexture'), 'Reader used a fallback renderer');
        final frames = events.where((e) => e.kind == TraceEventKind.framePresented)
          .map((e) => e.payload['frame']).toSet();
        _require(kind == 'static' || frames.length >= 3, 'actual animation did not advance');
        _require(_trace.events.every((e) => e.kind != TraceEventKind.taskFailed),
          'production media task failed');
        final routeExit = _clock.elapsedMicroseconds;
        _status('Texture 重入验收');
        await _frames(2);
        _require(_textures().isEmpty, 'unmounted Reader still has a Texture view');
        await _wait(() => _calls.any((r) => r['method'] == 'release' &&
          r['texture_id'] == texture && r['success'] == true));
        final release = _calls.singleWhere((r) => r['method'] == 'release' &&
          r['texture_id'] == texture);
        _require((release['start_us'] as int) >= routeExit,
          'used texture was released before the actual route exit');
        _require(_trace.events.any((e) => e.kind == TraceEventKind.readerSessionRetained &&
          e.sessionId == session.sessionId), 'route did not enter production retention');
        // Negative control: retired native output is inaccessible. This is not
        // a frame submission or a substitute for observing the release reply.
        var rejected = false;
        try {
          await const MethodChannel('dev.zic/texture').invokeMethod<void>(
            'redraw', <String, Object?>{'textureId': texture});
        } on PlatformException catch (error) {
          rejected = error.code == 'unknown_texture';
        }
        _require(rejected, 'retired platform output remains accessible');
        await Future<void>.delayed(const Duration(milliseconds: 250));
        _require(!_calls.any((r) => r['method'] == 'present' &&
          r['texture_id'] == texture && (r['start_us'] as int) > (release['reply_us'] as int)),
          'late presentation revived a released native output');
        await _record(<String, Object?>{
          'case': '$kind-entry-$entry', 'status': 'passed', 'start_us': begin,
          'session_id': session.sessionId, 'same_exact_retained_session': entry > 0,
          'texture_id': texture, 'native_create': creates.single,
          'native_present_replies': presents.length, 'frame_indices': frames.toList(),
          'renderer': 'androidTexture', 'route_exit_us': routeExit,
          'native_release': release, 'retired_native_output_rejected': rejected,
          'late_present_after_release_reply': false, 'input_reads': _reads - beforeReads,
          'retirement_before_TTL': true,
        });
      }
    }
    await factory.disposeRetainedSessions().timeout(const Duration(seconds: 20));
    await factory.disposeTransferRuntimes().timeout(const Duration(seconds: 20));
    await media.shutdownComposition().timeout(const Duration(seconds: 20));
    final created = _calls.where((r) => r['method'] == 'create' && r['success'] == true)
      .map((r) => r['texture_id']).toSet();
    final released = _calls.where((r) => r['method'] == 'release' && r['success'] == true)
      .map((r) => r['texture_id']).toSet();
    _require(created.difference(released).isEmpty && coordinator.networkLane.isIdle,
      'composition shutdown left native outputs or lane work');
    passed = true;
    await _record(<String, Object?>{
      'case': 'complete', 'status': 'passed', 'cases': 6, 'host_pid': pid,
      'unique_used_texture_ids': allUsed.toList(), 'created_ids': created.toList(),
      'released_ids': released.toList(), 'all_platform_outputs_retired': true,
      'production_modified': false, 'user_stores_opened': false,
      'source_revision_or_active_task_retirement_proven': false,
      'final_physical_display_performance_proven': false,
    });
  } on Object catch (error, stack) {
    await _record(<String, Object?>{'case': 'complete', 'status': 'failed',
      'error': error.toString(), 'stack': stack.toString()});
  } finally {
    _status(passed ? 'Texture 重入验收通过' : 'Texture 重入验收失败');
    await _frames(2);
    await factory.disposeRetainedSessions();
    await factory.disposeTransferRuntimes();
    await media.shutdownComposition();
    raster.clearPresentationRasters();
  }
}

Set<int> _textures() {
  final result = <int>{};
  void visit(Element element) {
    final widget = element.widget;
    if (widget is Texture) result.add(widget.textureId);
    element.visitChildElements(visit);
  }
  final root = WidgetsBinding.instance.rootElement;
  if (root != null) visit(root);
  return result;
}

Future<void> _wait(bool Function() ready) async {
  final deadline = Stopwatch()..start();
  while (!ready()) {
    _require(deadline.elapsed < const Duration(seconds: 20), 'platform retirement timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> _frames(int count) async {
  for (var i = 0; i < count; i++) {
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
  }
}

void _status(String text) => runApp(MaterialApp(key: UniqueKey(),
  home: Scaffold(body: Center(child: Text(text)))));

Future<void> _record(Map<String, Object?> row) async {
  _cases.add(<String, Object?>{'record_us': _clock.elapsedMicroseconds, ...row});
  await File('$_output.trace.jsonl').writeAsString(
    '${_trace.events.map((e) => jsonEncode(e.toJson())).join('\n')}\n', flush: true);
  await File('$_output.wire.json').writeAsString(jsonEncode(_calls), flush: true);
  await File(_output).writeAsString(jsonEncode(_cases), flush: true);
  debugPrint('ZIC_READER_USED_TEXTURE_EVENT ${jsonEncode(row)}');
}

void _require(bool condition, String reason) {
  if (!condition) throw StateError(reason);
}

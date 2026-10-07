import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bridge/bridge.dart';
import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_media_ui/local_media_ui.dart';
// Test-only transparent observation of the existing native cursor capability.
// ignore: depend_on_referenced_packages
import 'package:media/media.dart';
import 'package:pipeline_native/pipeline_native.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';
import 'package:reader_runtime/reader_runtime.dart';
import 'package:telemetry/telemetry.dart';
import 'package:zic/startup_platform.dart';

final _clock = Stopwatch()..start();
final _events = <Map<String, Object?>>[];
final _wire = <Map<String, Object?>>[];
final _decodes = <_DecodeObservation>[];
final _cursors = <_CursorObservation>[];
final _uploads = <Map<String, Object?>>[];
final _trace = _Trace();
late String _output;
PipelineReaderSession? _mounted;
Completer<_DecodeObservation>? _selected;
int _view = 0;
int _reads = 0;

final class _Binding extends WidgetsFlutterBinding {
  @override
  BinaryMessenger createBinaryMessenger() => _Messenger(super.createBinaryMessenger());
}

final class _Messenger implements BinaryMessenger {
  _Messenger(this.delegate);
  final BinaryMessenger delegate;
  static const codec = StandardMethodCodec();
  @override
  Future<ByteData?>? send(String channel, ByteData? data) {
    if (channel != 'dev.zic/texture' || data == null) return delegate.send(channel, data);
    final call = codec.decodeMethodCall(data);
    final args = call.arguments is Map ? call.arguments as Map : const <Object?, Object?>{};
    final row = <String, Object?>{'method':call.method,'begin_us':_clock.elapsedMicroseconds,
      'view':_view,'texture_id':args['textureId'],'frame_index':args['frameIndex']};
    _wire.add(row);
    final future = delegate.send(channel, data);
    future?.then<void>((reply) {
      row['end_us'] = _clock.elapsedMicroseconds;
      try {
        final result = codec.decodeEnvelope(reply!);
        if (call.method == 'create') row['texture_id'] = (result as Map)['textureId'];
        row['success'] = true;
      } on PlatformException catch (error) {
        row['success'] = false;
        row['error_code'] = error.code;
      }
    }, onError:(Object error, StackTrace stack) {
      row['end_us'] = _clock.elapsedMicroseconds;
      row['success'] = false;
      row['error'] = error.toString();
    });
    return future;
  }
  @override
  void setMessageHandler(String channel, MessageHandler? handler) => delegate.setMessageHandler(channel,handler);
  @override
  Future<void> handlePlatformMessage(String channel, ByteData? data, ui.PlatformMessageResponseCallback? callback) =>
      // ignore: deprecated_member_use
      delegate.handlePlatformMessage(channel,data,callback);
}

final class _Trace implements TraceSink {
  final memory = MemoryTraceSink();
  final retentions = <Map<String, Object?>>[];
  @override
  void record(TraceEvent event) {
    memory.record(event);
    if (event.kind == TraceEventKind.readerSessionRetained) {
      retentions.add(<String, Object?>{'observed_us':_clock.elapsedMicroseconds,
        'view':_view,'session_id':event.sessionId,'payload':event.payload});
    }
  }
}

final class _Factory implements PipelineMediaRuntimeFactory {
  _Factory(this.delegate);
  final NativePipelineMediaRuntimeFactory delegate;
  @override
  PipelineMediaRuntime create({required String sessionId, required MonoClock clock, required TraceSink traceSink}) =>
      _Runtime(delegate.create(sessionId:sessionId,clock:clock,traceSink:traceSink));
}

final class _Runtime implements PipelineMediaRuntime, PipelineOutputPrewarmer {
  _Runtime(this.delegate);
  final PipelineMediaRuntime delegate;
  @override
  SourceFactory get sources => delegate.sources;
  @override
  CursorFactory get cursors => _CursorFactory(delegate.cursors);
  @override
  FrameUploader get uploader => _Uploader(delegate.uploader);
  @override
  PipelineOutputProjector get outputs => delegate.outputs;
  @override
  PipelineFrameScheduler get frameScheduler => delegate.frameScheduler;
  @override
  RendererKind get renderer => delegate.renderer;
  @override
  Future<void> prewarmOutput({required int width, required int height}) =>
      (delegate as PipelineOutputPrewarmer).prewarmOutput(width:width,height:height);
  @override
  Future<void> close() => delegate.close();
}

final class _Uploader implements FrameUploader {
  _Uploader(this.delegate);
  final FrameUploader delegate;
  @override
  Future<OutputFrame> upload({required DecodeId id, required FrameRef frame}) {
    final row = <String, Object?>{'view':_view,'begin_us':_clock.elapsedMicroseconds,
      'frame_index':frame.index};
    _uploads.add(row);
    final future = delegate.upload(id:id,frame:frame);
    future.then<void>((_) { row['end_us'] = _clock.elapsedMicroseconds; row['success'] = true; },
      onError:(Object error, StackTrace stack) {
        row['end_us'] = _clock.elapsedMicroseconds; row['success'] = false; row['error'] = error.toString();
      });
    return future;
  }
  @override
  void release(DecodeId id) => delegate.release(id);
}

final class _CursorObservation {
  _CursorObservation(this.native, this.source, this.view);
  final NativeCursor native;
  final NativeSource source;
  final int view;
  int? disposeBegin;
  int? disposeEnd;
  Map<String, Object?> json() => <String, Object?>{'view':view,
    'dispose_begin_us':disposeBegin,'dispose_end_us':disposeEnd,
    'native_cursor_disposed':native.disposed,'native_source_disposed':source.disposed};
}

final class _DecodeObservation {
  _DecodeObservation(this.cursor, this.control): begin = _clock.elapsedMicroseconds, view = _view;
  final _CursorObservation cursor;
  final TaskControl? control;
  final int begin;
  final int view;
  int? end;
  int? cancelledObserved;
  CursorStep? step;
  int nativeMicros = 0;
  int workerQueueMicros = 0;
  int workerReadyMicros = 0;
  int? frameIndex;
  String? failure;
  final nativePhases = <String, int>{};
  int nativeInnerMaxMicros = 0;
  String? nativeInnerMaxPhase;
  bool get pending => end == null;
  // One Rust Instant-measured phase lies wholly inside the delegate call.
  // Its start is no later than E-D and its end no earlier than B+D.
  // Never add potentially nested phases or use the worker's outer Stopwatch.
  bool physicallyCovers(int at) => step?.kind == CursorStepKind.frame &&
      nativeInnerMaxMicros > 0 && end != null &&
      end! - nativeInnerMaxMicros + 1000 < at &&
      at < begin + nativeInnerMaxMicros - 1000;
  Map<String, Object?> json() => <String, Object?>{'view':view,'begin_us':begin,'end_us':end,
    'cancelled_observed_us':cancelledObserved,'cancelled':control?.cancelled,
    'step':step?.kind.name,'frame_index':frameIndex,
    'frame_disposed':step?.frame?.disposed,'native_decode_us':nativeMicros,
    'worker_queue_us':workerQueueMicros,'worker_ready_us':workerReadyMicros,
    'native_phases_us':nativePhases,'native_inner_max_phase':nativeInnerMaxPhase,
    'native_inner_max_us':nativeInnerMaxMicros,'failure':failure};
}

final class _CursorFactory implements CursorFactory {
  _CursorFactory(this.delegate);
  final CursorFactory delegate;
  @override
  CursorBinding create({required DecodeId id, required EncodedSource source, required int epoch}) {
    final binding = delegate.create(id:id,source:source,epoch:epoch);
    final row = _CursorObservation(binding.frames as NativeCursor,source as NativeSource,_view);
    _cursors.add(row);
    return CursorBinding(frames:_Cursor(binding.frames as PrioritizableScheduledFrameCursor,row),loop:binding.loop);
  }
}

final class _Cursor implements PrioritizableScheduledFrameCursor {
  _Cursor(this.delegate,this.observation);
  final PrioritizableScheduledFrameCursor delegate;
  final _CursorObservation observation;
  @override
  int get epoch => delegate.epoch;
  @override
  Future<CursorStep> decodeNext() => decodeNextScheduled(DecodeExecutionClass.nonCurrent);
  @override
  DecodePriorityPromotion promotePendingDecodeToCurrent() => delegate.promotePendingDecodeToCurrent();
  @override
  Future<CursorStep> decodeNextScheduled(DecodeExecutionClass kind, {TaskControl? control}) {
    final row = _DecodeObservation(observation,control);
    _decodes.add(row);
    final future = delegate.decodeNextScheduled(kind,control:control);
    control?.whenCancelled.then<void>((_) { row.cancelledObserved = _clock.elapsedMicroseconds; });
    future.then<void>((step) {
      row.end = _clock.elapsedMicroseconds;
      row.step = step;
      final frame = step.frame;
      row.frameIndex = frame?.index;
      if (frame is FrameDecodeTiming) {
        final timing = frame as FrameDecodeTiming;
        row.nativeMicros = timing.nativeDecodeMicros;
        row.workerQueueMicros = timing.workerQueueMicros;
        row.workerReadyMicros = timing.workerReadyMicros;
      }
      if (frame is FrameNativeDecodeObservation) {
        final native = frame as FrameNativeDecodeObservation;
        row.nativePhases.addAll(<String, int>{
          'prepare':native.nativePrepareMicros,
          'canvas_prepare':native.nativeCanvasPrepareMicros,
          'fragment_decode':native.nativeFragmentDecodeMicros,
          'composite':native.nativeCompositeMicros,
          'frame_copy':native.nativeFrameCopyMicros,
        });
        for (final phase in row.nativePhases.entries) {
          if (phase.value > row.nativeInnerMaxMicros) {
            row.nativeInnerMaxMicros = phase.value;
            row.nativeInnerMaxPhase = phase.key;
          }
        }
      }
    }, onError:(Object error, StackTrace stack) {
      row.end = _clock.elapsedMicroseconds; row.failure = error.toString();
    });
    if (_selected != null && !_selected!.isCompleted) {
      Timer(const Duration(milliseconds:120), () {
        if (_selected == null || _selected!.isCompleted || !row.pending || control?.cancelled == true ||
            observation.source.disposed || !observation.source.sealed) {
          return;
        }
        _selected!.complete(row);
      });
    }
    return future;
  }
  @override
  void dispose() {
    observation.disposeBegin ??= _clock.elapsedMicroseconds;
    delegate.dispose();
    observation.disposeEnd ??= _clock.elapsedMicroseconds;
  }
}

Future<void> main() async {
  _Binding();
  _status('Native 任务退出验收');
  await waitForFirstFlutterUiDisplayed();
  for (final plugin in <String>['texture_bridge','reader_runtime']) { await attachAndroidPlugin(plugin); }
  final support = await getStartupApplicationSupportPath();
  _require(support != null && support.contains('/dev.zic.activenativeretirement/'), 'fixture is not package-isolated');
  _output = '$support/native-retirement-results.json';
  final native = NativePipelineMediaRuntimeFactory();
  await native.prewarm();
  final coordinator = DownloadResourceCoordinator();
  final raster = PipelinePresentationRasterCache();
  final presentation = PipelineStaticPresentation(raster);
  final factory = PipelineReaderSessionFactory(mediaRuntimeFactory:_Factory(native),
    pageDownloadLane:coordinator.networkLane,artifactReadScheduler:coordinator.localReadScheduler,
    speculativeEncodedReadBudget:coordinator.speculativeEncodedReadBudget,
    bytesLoader:(asset,control) async { _reads++; return File.fromUri(asset.uri).readAsBytes(); },
    externalPresentationPrewarmer:presentation.prewarm,presentationCacheAuthority:presentation.cacheAuthority);
  var passed = false;
  try {
    final input = File('$support/inputs/decode-4096.webp');
    _require(await input.exists(), 'natural decode input missing');
    for (final mode in <String>['drain','rapid-reentry']) {
      final record = ImportedChapterRecord(directoryId:'native-active:$mode',displayName:mode,
        sourceId:'local-folder',comicId:'native-active',chapterId:mode,sourceRevision:'native-active-r1',
        pages:<ImportedPageRecord>[ImportedPageRecord(displayName:'input.webp',sourceId:input.uri.toString(),
          pageId:'page-0',mediaFormat:'webp',contentKindHint:ContentKindHint.webp,byteLength:await input.length())]);
      final oldFirst = Completer<void>();
      _view++;
      final oldView = _view;
      final beforeRetentions = _trace.retentions.length;
      _selected = Completer<_DecodeObservation>();
      _mount(record,factory,presentation,oldFirst);
      final active = await _selected!.future.timeout(const Duration(seconds:45));
      _selected = null;
      final original = _mounted!;
      _status('Native 任务退出验收');
      await _wait(() => _trace.retentions.length > beforeRetentions);
      final retained = _trace.retentions.last;
      final retiredAt = retained['observed_us'] as int;
      final pendingAtExit = active.pending;
      final sourceAliveAtExit = !active.cursor.source.disposed;
      final cursorAliveAtExit = !active.cursor.native.disposed;
      _require(active.control?.cancelled == true && pendingAtExit && sourceAliveAtExit && cursorAliveAtExit,
        'route did not exit while the selected original task retained its native resources');
      final readsBeforeReentry = _reads;
      Completer<void>? newFirst;
      var reenteredBeforeOldCompletion = false;
      if (mode == 'rapid-reentry') {
        _view++;
        newFirst = Completer<void>();
        _mount(record,factory,presentation,newFirst);
        await _wait(() => _mounted != null && _trace.memory.events.any((e) =>
          e.kind == TraceEventKind.readerSessionReused && e.sessionId == original.sessionId));
        reenteredBeforeOldCompletion = active.pending;
        _require(identical(_mounted,original) && reenteredBeforeOldCompletion,
          'rapid Reader reentry did not overlap the old original native Future');
      }
      await _wait(() => !active.pending);
      _require(active.physicallyCovers(retiredAt),
        'Rust internal timing does not conservatively prove execution at the actual route exit');
      await _wait(() => active.cursor.disposeEnd != null);
      _require(active.cursor.disposeBegin! >= active.end! && active.cursor.native.disposed,
        'native cursor retired before the original physical Future returned');
      _require(active.step?.frame?.disposed == true && !oldFirst.isCompleted,
        'late cancelled native frame survived or was presented by the retired Reader');
      if (newFirst != null) {
        await newFirst.future.timeout(const Duration(seconds:45));
        _require(_reads == readsBeforeReentry, 'warm exact body was unnecessarily loaded again');
        final fresh = _decodes.where((r) => r.view == _view && r.step?.kind == CursorStepKind.frame).toList();
        _require(fresh.isNotEmpty && !identical(fresh.first.cursor,active.cursor) &&
          fresh.first.frameIndex == 0 && !fresh.first.cursor.source.disposed,
          'reentry did not present a new cursor frame0 from a live source');
        _require(_textures().length == 1 && _wire.any((r) => r['method'] == 'present' &&
          r['view'] == _view && r['success'] == true), 'reentry did not present an actual native Texture');
        _status('Native 任务退出验收');
        await _frames(2);
      }
      await _wait(() => active.cursor.source.disposed);
      _require(!_decodes.any((r) => r.view == oldView && r.cursor.disposeBegin != null &&
        r.end != null && r.cursor.disposeBegin! < r.end!), 'old cursor was freed before an admitted decode returned');
      _require(_trace.memory.events.every((e) => e.kind != TraceEventKind.taskFailed), 'production task failure');
      await _record(<String, Object?>{'case':mode,'status':'passed','old_view':oldView,
        'session_id':original.sessionId,'retention':retained,'selected_decode':active.json(),
        'native_execution_at_actual_exit_proven':true,
        'native_inner_proof':<String, Object?>{
          'phase':active.nativeInnerMaxPhase,'duration_us':active.nativeInnerMaxMicros,
          'latest_phase_start_us':active.end!-active.nativeInnerMaxMicros,
          'earliest_phase_end_us':active.begin+active.nativeInnerMaxMicros,
          'retention_us':retiredAt,'margin_us':1000,
          'lower_slack_us':retiredAt-(active.end!-active.nativeInnerMaxMicros),
          'upper_slack_us':active.begin+active.nativeInnerMaxMicros-retiredAt,
        },'pending_at_exit':pendingAtExit,
        'source_alive_at_exit':sourceAliveAtExit,'cursor_alive_at_exit':cursorAliveAtExit,
        'native_cursor_retired_after_original_Future':true,'cancelled_frame_disposed':true,
        'reentered_before_old_completion':reenteredBeforeOldCompletion,'source_disposed_after_final_exit':true,
        'old_first_frame_callback':oldFirst.isCompleted,'new_first_frame_callback':newFirst?.isCompleted,
        'warm_reentry_extra_input_reads':_reads-readsBeforeReentry});
    }
    await factory.disposeRetainedSessions().timeout(const Duration(seconds:20));
    await factory.disposeTransferRuntimes().timeout(const Duration(seconds:20));
    await native.shutdownComposition().timeout(const Duration(seconds:20));
    _require(_cursors.every((c) => c.native.disposed && c.source.disposed), 'native resources remain after drain');
    _require(_decodes.every((r) => !r.pending && (r.step?.frame == null || r.step!.frame!.disposed)),
      'original native work or returned frames remain after composition drain');
    passed = true;
    await _record(<String, Object?>{'case':'complete','status':'passed','host_pid':pid,
      'native_decode_cases':2,'production_modified':false,'user_stores_opened':false,
      'active_upload_retirement_proven':false,'source_revision_retirement_proven':false,
      'final_physical_display_performance_proven':false});
  } on Object catch (error, stack) {
    await _record(<String, Object?>{'case':'complete','status':'failed','error':error.toString(),'stack':stack.toString()});
  } finally {
    _selected = null;
    _status(passed ? 'Native 任务退出验收通过' : 'Native 任务退出验收失败');
    await _frames(2);
    await factory.disposeRetainedSessions();
    await factory.disposeTransferRuntimes();
    await native.shutdownComposition();
    raster.clearPresentationRasters();
  }
}

void _mount(ImportedChapterRecord record, PipelineReaderSessionFactory factory,
    PipelineStaticPresentation presentation, Completer<void> first) {
  _mounted = null;
  final chapter = record.toManifest();
  runApp(MaterialApp(key:UniqueKey(),home:PipelineReaderSessionHost(chapter:chapter,factory:factory,traceSink:_trace,
    builder:(context,pipeline) {
      _mounted = pipeline;
      return ReaderRuntimeScreen(chapter:chapter,pipeline:pipeline,
        artifactPageBuilder:(context,asset,reportFirstFrame,runtime) => LocalImagePlayer(
          key:ValueKey<String>(asset.assetKey),
          image:PickedImage(file:XFile(asset.uri.toString()),format:LocalImageFormat.webp,
            displayName:asset.pageId,sourceId:asset.uri.toString(),byteLength:asset.byteLength),
          presentationBytesLoader:(_,token) => runtime.loadPresentationBytes(token),
          pageStream:runtime.pageStream,pageOutput:runtime.pageOutput,staticPresentation:presentation,
          onPlaybackCapabilityChanged:runtime.reportPlaybackCapability,
          onDimensionsChanged:(size) => runtime.reportDimensions(size.width.round(),size.height.round()),
          onFirstFrame:() { reportFirstFrame(); if (!first.isCompleted) first.complete(); },
          traceClock:runtime.clock,traceSink:runtime.traceSink,traceSessionId:runtime.sessionId,
          demandRevision:runtime.demandRevision,downloadIdentity:runtime.pageStream.identity,
          playback:runtime.playback,fit:runtime.mediaFit));
    })));
}

Set<int> _textures() {
  final ids = <int>{};
  void visit(Element e) { if (e.widget is Texture) ids.add((e.widget as Texture).textureId); e.visitChildElements(visit); }
  final root = WidgetsBinding.instance.rootElement;
  if (root != null) visit(root);
  return ids;
}
void _status(String text) => runApp(MaterialApp(key:UniqueKey(),home:Scaffold(body:Center(child:Text(text)))));
Future<void> _frames(int count) async {
  for (var i = 0; i < count; i++) { WidgetsBinding.instance.scheduleFrame(); await WidgetsBinding.instance.endOfFrame; }
}
Future<void> _wait(bool Function() ready) async {
  final timer = Stopwatch()..start();
  while (!ready()) { _require(timer.elapsed < const Duration(seconds:30), 'original lifecycle did not complete');
    await Future<void>.delayed(const Duration(milliseconds:1)); }
}
Future<void> _record(Map<String, Object?> event) async {
  _events.add(<String, Object?>{'record_us':_clock.elapsedMicroseconds,...event});
  await File('$_output.trace.jsonl').writeAsString('${_trace.memory.events.map((e) => jsonEncode(e.toJson())).join('\n')}\n',flush:true);
  await File('$_output.observers.json').writeAsString(jsonEncode(<String, Object?>{
    'decodes':_decodes.map((r) => r.json()).toList(),'cursors':_cursors.map((c) => c.json()).toList(),
    'uploads':_uploads,'wire':_wire}),flush:true);
  await File(_output).writeAsString(jsonEncode(_events),flush:true);
}
void _require(bool condition, String message) { if (!condition) throw StateError(message); }

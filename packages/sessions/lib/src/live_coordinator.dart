import 'dart:async';

import 'package:domain/domain.dart';
import 'package:media/media.dart';
import 'package:pipeline/pipeline.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'coordinator.dart';
import 'decode_registry.dart';
import 'download_job.dart';
import 'download_registry.dart';
import 'download_session.dart';
import 'net_lane.dart';
import 'retry_policy.dart';
import 'upload_registry.dart';

typedef TransportPick = Transport Function(Uri uri);
typedef DecodeWork = Future<void> Function(
  DecodeId id,
  DecodeDemand demand,
  CancelToken token,
);
typedef UploadWork = Future<void> Function(
  DecodeId id,
  UploadDemand demand,
  CancelToken token,
);
typedef Sleep = Future<void> Function(Duration delay);

Future<void> _defaultSleep(Duration delay) => Future<void>.delayed(delay);

final class LiveCoordinator implements Coordinator {
  LiveCoordinator({
    required this.registry,
    required this.transportFor,
    required this.clock,
    this.traceSink = const NoopTraceSink(),
    this.retry = const RetryPolicy(),
    this.sleep = _defaultSleep,
    this.onDecode,
    this.onUpload,
    this.decodes,
    this.uploads,
    NetLane? net,
    DecodeLane? decode,
    UploadLane? upload,
  })  : net = net ?? NetLane(maxActive: 3),
        decode = decode ?? DecodeLane(maxActive: 2),
        upload = upload ?? UploadLane(maxActive: 1) {
    retry.validate();
    if (onDecode != null && decodes != null) {
      throw ArgumentError('onDecode and decodes are mutually exclusive');
    }
    if (onUpload != null && uploads != null) {
      throw ArgumentError('onUpload and uploads are mutually exclusive');
    }
  }

  final DownloadRegistry registry;
  final TransportPick transportFor;
  final MonoClock clock;
  final TraceSink traceSink;
  final RetryPolicy retry;
  final Sleep sleep;
  final DecodeWork? onDecode;
  final UploadWork? onUpload;
  final DecodeRegistry? decodes;
  final UploadRegistry? uploads;
  final NetLane net;
  final DecodeLane decode;
  final UploadLane upload;

  final Map<DownloadId, DownloadDemand> _downloads =
      <DownloadId, DownloadDemand>{};
  final Map<DecodeId, DecodeDemand> _decodes = <DecodeId, DecodeDemand>{};
  final Map<DecodeId, UploadDemand> _uploads = <DecodeId, UploadDemand>{};
  final Map<DownloadId, SourceListener> _sourceListeners =
      <DownloadId, SourceListener>{};
  int _revision = 0;

  Map<DownloadId, DownloadDemand> get demands =>
      Map<DownloadId, DownloadDemand>.unmodifiable(_downloads);
  Map<DecodeId, DecodeDemand> get decodeDemands =>
      Map<DecodeId, DecodeDemand>.unmodifiable(_decodes);
  Map<DecodeId, UploadDemand> get uploadDemands =>
      Map<DecodeId, UploadDemand>.unmodifiable(_uploads);

  @override
  void reconcile(String sessionId, PipelineDelta update) {
    _revision = update.plan.revision;
    _reconcileDownloads(sessionId, update.diff.downloads);
    _reconcileDecodes(sessionId, update.diff.decodes);
    _reconcileUploads(sessionId, update.diff.uploads);
  }

  Future<void> idle() async {
    while (true) {
      await net.idle();
      await decode.idle();
      await upload.idle();
      await Future<void>.delayed(Duration.zero);
      if (net.isIdle && decode.isIdle && upload.isIdle) {
        return;
      }
    }
  }

  bool freezePlayback(DecodeId id) => uploads?.freezePlayback(id) ?? false;

  bool resumePlayback(DecodeId id) => uploads?.resumePlayback(id) ?? false;

  bool advanceDueFrame(String sessionId, DecodeId id) {
    final frameIndex = uploads?.takeDueFrame(id);
    if (frameIndex == null) {
      return false;
    }
    return advanceFrame(sessionId, id, frameIndex);
  }

  bool advanceFrame(
    String sessionId,
    DecodeId id,
    int frameIndex,
  ) {
    final registry = uploads;
    if (registry == null) {
      return false;
    }
    upload.cancel(id.key);
    if (!registry.advance(id, frameIndex)) {
      return false;
    }
    _wakeUpload(sessionId, id);
    _wakeDecodes(sessionId, id.download);
    return true;
  }

  Future<void> dispose() async {
    for (final entry in _sourceListeners.entries) {
      registry.find(entry.key)?.removeSourceListener(entry.value);
    }
    _sourceListeners.clear();
    for (final session in registry.sessions) {
      net.cancel(session.id.key);
    }
    final decodeRegistry = decodes;
    if (decodeRegistry != null) {
      for (final session in decodeRegistry.sessions) {
        decode.cancel(session.id.key);
      }
    } else {
      for (final id in _decodes.keys) {
        decode.cancel(id.key);
      }
    }
    final uploadRegistry = uploads;
    if (uploadRegistry != null) {
      for (final session in uploadRegistry.sessions) {
        upload.cancel(session.id.key);
      }
    } else {
      for (final id in _uploads.keys) {
        upload.cancel(id.key);
      }
    }
    _downloads.clear();
    _decodes.clear();
    _uploads.clear();
    await idle();
  }

  void _reconcileDownloads(
    String sessionId,
    MapDiff<DownloadId, DownloadDemand> diff,
  ) {
    for (final id in diff.removed) {
      _downloads.remove(id);
      net.cancelQueued(id.key);
      final session = registry.find(id);
      final listener = _sourceListeners.remove(id);
      if (listener != null) {
        session?.removeSourceListener(listener);
      }
      session?.detach();
    }
    for (final entry in <MapEntry<DownloadId, DownloadDemand>>[
      ...diff.added.entries,
      ...diff.changed.entries,
    ]) {
      _downloads[entry.key] = entry.value;
      final session = registry.get(entry.key)..attach();
      _watchSource(sessionId, entry.key, session);
      net.submit(
        key: entry.key.key,
        priority: entry.value.priority,
        task: (token) => _runDownload(sessionId, entry.key, session, token),
      );
    }
  }

  void _watchSource(
    String sessionId,
    DownloadId id,
    DownloadSession session,
  ) {
    if (_sourceListeners.containsKey(id)) {
      return;
    }
    void listener(IngressSnap snapshot) {
      if (snapshot.sourceReady) {
        _wakeDecodes(sessionId, id);
      }
    }
    _sourceListeners[id] = listener;
    session.addSourceListener(listener);
  }

  Future<void> _runDownload(
    String sessionId,
    DownloadId id,
    DownloadSession session,
    CancelToken token,
  ) async {
    for (var attempt = 1; ; attempt++) {
      token.throwIfCancelled();
      final demand = _downloads[id];
      if (demand == null ||
          demand.expirationRevision < _revision ||
          !session.demanded) {
        return;
      }
      try {
        await DownloadJob(
          transport: transportFor(id.canonicalUri),
          session: session,
        ).run(cancel: token);
        _wakeDecodes(sessionId, id);
        return;
      } on Object catch (error) {
        if (!retry.allows(error, attempt)) {
          if (error is Failure && error.code == ErrorCode.cancelled) {
            return;
          }
          _error(sessionId, id.key, 'network', error);
          return;
        }
        final delay = retry.delayAfter(attempt);
        traceSink.record(
          traceEvent(
            clock: clock,
            sessionId: sessionId,
            kind: TraceEventKind.retryScheduled,
            identityHash: id.key,
            revision: _revision,
            payload: <String, Object?>{
              'attempt': attempt + 1,
              'delayUs': delay.inMicroseconds,
              'error': '$error',
            },
          ),
        );
        await _sleepOrCancel(delay, token);
      }
    }
  }

  Future<void> _sleepOrCancel(Duration delay, CancelToken token) async {
    if (delay == Duration.zero) {
      token.throwIfCancelled();
      return;
    }
    await Future.any<void>(<Future<void>>[
      sleep(delay),
      token.whenCancelled,
    ]);
    token.throwIfCancelled();
  }

  void _reconcileDecodes(
    String sessionId,
    MapDiff<DecodeId, DecodeDemand> diff,
  ) {
    for (final id in diff.removed) {
      _decodes.remove(id);
      decode.cancel(id.key);
      decodes?.detach(id);
    }
    for (final entry in <MapEntry<DecodeId, DecodeDemand>>[
      ...diff.added.entries,
      ...diff.changed.entries,
    ]) {
      _decodes[entry.key] = entry.value;
      final work = onDecode;
      final registry = decodes;
      if (work == null && registry == null) {
        _resourceTrace(
          sessionId,
          TraceEventKind.decodeDemand,
          entry.key.key,
          entry.value.priority,
        );
        continue;
      }
      final decodeWork = work;
      final decodeRegistry = registry;
      final submit = diff.changed.containsKey(entry.key)
          ? decode.replace
          : decode.submit;
      submit(
        key: entry.key.key,
        priority: entry.value.priority,
        task: (token) async {
          final current = _decodes[entry.key];
          if (current == null || current.expirationRevision < _revision) {
            return;
          }
          try {
            if (decodeWork != null) {
              await decodeWork(entry.key, current, token);
            } else if (decodeRegistry != null) {
              await decodeRegistry.fill(
                entry.key,
                current,
                token,
                revision: _revision,
                preparedDepth: uploads?.preparedDepth(entry.key) ?? 0,
              );
            }
            _wakeUpload(sessionId, entry.key);
          } on Object catch (error) {
            if (error is! Failure || error.code != ErrorCode.cancelled) {
              _error(sessionId, entry.key.key, 'decode', error);
            }
          }
        },
      );
    }
  }

  void _wakeDecodes(String sessionId, DownloadId downloadId) {
    for (final entry in _decodes.entries) {
      if (entry.key.download != downloadId) {
        continue;
      }
      final id = entry.key;
      final demand = entry.value;
      decode.follow(
        key: id.key,
        priority: demand.priority,
        task: (token) async {
          final current = _decodes[id];
          if (current == null || current.expirationRevision < _revision) {
            return;
          }
          try {
            final work = onDecode;
            if (work != null) {
              await work(id, current, token);
            } else {
              final registry = decodes;
              if (registry != null) {
                await registry.fill(
                  id,
                  current,
                  token,
                  revision: _revision,
                  preparedDepth: uploads?.preparedDepth(id) ?? 0,
                );
              }
            }
            _wakeUpload(sessionId, id);
          } on Object catch (error) {
            if (error is! Failure || error.code != ErrorCode.cancelled) {
              _error(sessionId, id.key, 'decode', error);
            }
          }
        },
      );
    }
  }

  void _reconcileUploads(
    String sessionId,
    MapDiff<DecodeId, UploadDemand> diff,
  ) {
    for (final id in diff.removed) {
      _uploads.remove(id);
      upload.cancel(id.key);
      uploads?.detach(id);
    }
    for (final entry in <MapEntry<DecodeId, UploadDemand>>[
      ...diff.added.entries,
      ...diff.changed.entries,
    ]) {
      _uploads[entry.key] = entry.value;
      if (onUpload == null && uploads == null) {
        _resourceTrace(
          sessionId,
          TraceEventKind.uploadDemand,
          entry.key.key,
          entry.value.priority,
        );
        continue;
      }
      _submitUpload(
        sessionId,
        entry.key,
        entry.value,
        replace: diff.changed.containsKey(entry.key),
      );
    }
  }

  void _wakeUpload(String sessionId, DecodeId id) {
    final demand = _uploads[id];
    if (demand == null || (onUpload == null && uploads == null)) {
      return;
    }
    _submitUpload(sessionId, id, demand, follow: true);
  }

  void _submitUpload(
    String sessionId,
    DecodeId id,
    UploadDemand demand, {
    bool replace = false,
    bool follow = false,
  }) {
    final submit = replace
        ? upload.replace
        : follow
            ? upload.follow
            : upload.submit;
    submit(
      key: id.key,
      priority: demand.priority,
      task: (token) async {
        final current = _uploads[id];
        if (current == null || current.expirationRevision < _revision) {
          return;
        }
        try {
          final work = onUpload;
          if (work != null) {
            await work(id, current, token);
          } else {
            final registry = uploads;
            if (registry != null) {
              await registry.prepare(
                id,
                current,
                token,
                revision: _revision,
              );
            }
          }
        } on Object catch (error) {
          if (error is! Failure || error.code != ErrorCode.cancelled) {
            _error(sessionId, id.key, 'upload', error);
          }
        }
      },
    );
  }

  void _resourceTrace(
    String sessionId,
    TraceEventKind kind,
    String key,
    int priority,
  ) {
    traceSink.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: kind,
        identityHash: key,
        revision: _revision,
        payload: <String, Object?>{'priority': priority},
      ),
    );
  }

  void _error(
    String sessionId,
    String identity,
    String lane,
    Object error,
  ) {
    traceSink.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: TraceEventKind.taskFailed,
        identityHash: identity,
        revision: _revision,
        payload: <String, Object?>{'lane': lane, 'error': '$error'},
      ),
    );
  }
}

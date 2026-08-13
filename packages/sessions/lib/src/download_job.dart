import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:storage/storage.dart';
import 'package:transport/transport.dart';

import 'download_session.dart';
import 'net_lane.dart';
import 'source_progress.dart';
import 'webp_frame_prefix_tracker.dart';

const int _validatorlessResumeProbeBytes = 64 * 1024;

typedef FullBodyCatchupPermission = bool Function(int preservedLength);

final class DownloadCatchupDeferred implements Exception {
  const DownloadCatchupDeferred({required this.preservedLength});

  final int preservedLength;
}

final class DownloadJob {
  const DownloadJob({
    required this.transport,
    required this.session,
    this.requestUri,
    this.allowFullBodyCatchup,
    this.attachLegacyDemand = true,
  });

  final Transport transport;
  final DownloadSession session;

  /// Exact source request identity selected by the active consumer.
  ///
  /// The physical [DownloadSession] may be anchored to a different, directly
  /// verified equivalent [DownloadId]. Physical artifact/writer/resume state
  /// stays on [session], while transport opens MUST use this exact provider URI.
  /// Legacy callers default to the session anchor URI.
  final Uri? requestUri;

  Uri get _requestUri => requestUri ?? session.id.canonicalUri;

  final FullBodyCatchupPermission? allowFullBodyCatchup;
  final bool attachLegacyDemand;

  Future<DownloadSnapshot> run({
    String? expectedChecksum,
    CancelToken? cancel,
  }) async {
    final lease = session.beginRun();
    try {
      cancel?.throwIfCancelled();
      await _run(expectedChecksum: expectedChecksum, cancel: cancel);
    } finally {
      session.endNetworkAttemptProgress();
      session.endRun(lease);
    }
    return session.snapshot;
  }

  Future<void> _run({
    String? expectedChecksum,
    CancelToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    if (session.state == DownloadState.promoted) {
      return;
    }
    await session.restore();
    if (session.state == DownloadState.promoted) {
      return;
    }
    if (session.committedLength > 0 &&
        session.totalLength == session.committedLength) {
      final writer = session.acquireWriter();
      await session.seal(
        writer,
        expectedLength: session.totalLength,
        expectedChecksum: expectedChecksum,
      );
      await session.promote();
      return;
    }

    if (attachLegacyDemand) {
      session.attach();
    }
    session.queue();

    final preservedLength = session.committedLength;
    final preservedTotalLength = session.totalLength;
    final resumeValidators = session.resumeValidatorsFor(_requestUri);
    final providerValidatorMismatch = preservedLength > 0 &&
        session.hasValidatorsForOtherRequest(_requestUri);
    var start = preservedLength;
    var fullBodyCatchup = false;
    var validatorlessRangeProbe = false;
    var probeStart = 0;
    var probeBytes = 0;
    ByteResponse response;
    cancel?.throwIfCancelled();
    if (start > 0 && !resumeValidators.canResume) {
      if (preservedTotalLength != null &&
          preservedTotalLength >= start) {
        probeBytes = start < _validatorlessResumeProbeBytes
            ? start
            : _validatorlessResumeProbeBytes;
        probeStart = start - probeBytes;
        response = await _openRange(probeStart, cancel);
        await _discardIfCancelled(cancel, response);
        final usableProbe = response.isPartial &&
            response.rangeStart == probeStart &&
            response.totalLength == preservedTotalLength;
        if (usableProbe) {
          validatorlessRangeProbe = true;
        } else if (response.statusCode == 200 && response.rangeStart == 0) {
          await _deferCostlyFullBodyCatchupIfNeeded(
            preservedLength: preservedLength,
            cancel: cancel,
            response: response,
            diagnostics: <String, Object?>{
              'resumeProbeStart': probeStart,
              'resumeProbeBytes': probeBytes,
              'resumeProbeStatusCode': response.statusCode,
              'resumeProbeAccepted': false,
              'fullBodyResponseReused': true,
              if (providerValidatorMismatch) 'providerValidatorMismatch': true,
            },
          );
          fullBodyCatchup = true;
          session.recordResume(
            restarted: true,
            strategy: 'full-body-prefix-catchup',
            playablePrefixPreserved: true,
            diagnostics: <String, Object?>{
              'resumeProbeStart': probeStart,
              'resumeProbeBytes': probeBytes,
              'resumeProbeStatusCode': response.statusCode,
              'resumeProbeAccepted': false,
              'duplicatePrefixBytes': 0,
              'fullBodyResponseReused': true,
              if (providerValidatorMismatch) 'providerValidatorMismatch': true,
            },
          );
        } else {
          final probeStatusCode = response.statusCode;
          await response.discard();
          cancel?.throwIfCancelled();
          await _deferCostlyFullBodyCatchupIfNeeded(
            preservedLength: preservedLength,
            cancel: cancel,
            diagnostics: <String, Object?>{
              'resumeProbeStart': probeStart,
              'resumeProbeBytes': probeBytes,
              'resumeProbeStatusCode': probeStatusCode,
              'resumeProbeAccepted': false,
            },
          );
          response = await _open(0, cancel);
          fullBodyCatchup = true;
          session.recordResume(
            restarted: true,
            strategy: 'full-body-prefix-catchup',
            playablePrefixPreserved: true,
            diagnostics: <String, Object?>{
              'resumeProbeStart': probeStart,
              'resumeProbeBytes': probeBytes,
              'resumeProbeStatusCode': probeStatusCode,
              'resumeProbeAccepted': false,
              'duplicatePrefixBytes': 0,
              'fullBodyResponseReused': false,
              if (providerValidatorMismatch) 'providerValidatorMismatch': true,
            },
          );
        }
      } else {
        await _deferCostlyFullBodyCatchupIfNeeded(
          preservedLength: preservedLength,
          cancel: cancel,
          diagnostics: <String, Object?>{
            'resumeProbeAttempted': false,
            if (providerValidatorMismatch) 'providerValidatorMismatch': true,
          },
        );
        response = await _open(0, cancel);
        fullBodyCatchup = true;
        session.recordResume(
          restarted: true,
          strategy: 'full-body-prefix-catchup',
          playablePrefixPreserved: true,
          diagnostics: <String, Object?>{
            'resumeProbeAttempted': false,
            'duplicatePrefixBytes': 0,
            if (providerValidatorMismatch) 'providerValidatorMismatch': true,
          },
        );
      }
    } else {
      response = await _open(start, cancel);
      await _discardIfCancelled(cancel, response);
      if (start > 0 &&
          response.disposition == ByteResponseDisposition.durableImmutable) {
        if (response.statusCode == 200 && response.rangeStart == 0) {
          await _deferCostlyFullBodyCatchupIfNeeded(
            preservedLength: preservedLength,
            cancel: cancel,
            response: response,
            diagnostics: const <String, Object?>{
              'strongRangeRejected': true,
              'fullBodyResponseReused': true,
            },
          );
          fullBodyCatchup = true;
          session.recordResume(
            restarted: true,
            strategy: 'full-body-prefix-catchup',
            playablePrefixPreserved: true,
            diagnostics: const <String, Object?>{
              'strongRangeRejected': true,
              'fullBodyResponseReused': true,
              'duplicatePrefixBytes': 0,
            },
          );
        } else {
          await response.discard();
          cancel?.throwIfCancelled();
          await _deferCostlyFullBodyCatchupIfNeeded(
            preservedLength: preservedLength,
            cancel: cancel,
            diagnostics: const <String, Object?>{
              'strongRangeRejected': true,
            },
          );
          response = await _open(0, cancel);
          fullBodyCatchup = true;
          session.recordResume(
            restarted: true,
            strategy: 'full-body-prefix-catchup',
            playablePrefixPreserved: true,
            diagnostics: const <String, Object?>{
              'strongRangeRejected': true,
              'fullBodyResponseReused': false,
              'duplicatePrefixBytes': 0,
            },
          );
        }
      } else if (start > 0) {
        try {
          requireResumeResponse(
            expectedStart: start,
            expectedValidators: resumeValidators,
            response: response,
          );
          session.recordResume(
            restarted: false,
            strategy: 'strong-validator-range',
            playablePrefixPreserved: true,
            diagnostics: const <String, Object?>{
              'duplicatePrefixBytes': 0,
            },
          );
        } on Failure catch (error) {
          if (error.code != ErrorCode.resumeRejected) {
            rethrow;
          }
          if (response.statusCode == 200 && response.rangeStart == 0) {
            await _deferCostlyFullBodyCatchupIfNeeded(
              preservedLength: preservedLength,
              cancel: cancel,
              response: response,
              diagnostics: const <String, Object?>{
                'strongRangeRejected': true,
                'fullBodyResponseReused': true,
              },
            );
            fullBodyCatchup = true;
            session.recordResume(
              restarted: true,
              strategy: 'full-body-prefix-catchup',
              playablePrefixPreserved: true,
              diagnostics: const <String, Object?>{
                'strongRangeRejected': true,
                'fullBodyResponseReused': true,
                'duplicatePrefixBytes': 0,
              },
            );
          } else {
            await response.discard();
            cancel?.throwIfCancelled();
            await _deferCostlyFullBodyCatchupIfNeeded(
              preservedLength: preservedLength,
              cancel: cancel,
              diagnostics: const <String, Object?>{
                'strongRangeRejected': true,
              },
            );
            response = await _open(0, cancel);
            fullBodyCatchup = true;
            session.recordResume(
              restarted: true,
              strategy: 'full-body-prefix-catchup',
              playablePrefixPreserved: true,
              diagnostics: const <String, Object?>{
                'strongRangeRejected': true,
                'fullBodyResponseReused': false,
                'duplicatePrefixBytes': 0,
              },
            );
          }
        }
      }
    }
    await _discardIfCancelled(cancel, response);

    if ((start == 0 || fullBodyCatchup) && response.rangeStart != 0) {
      await response.discard();
      throw const Failure(
        code: ErrorCode.resumeRejected,
        message: 'full response did not start at offset zero',
      );
    }

    if (start == 0 && response.totalLength == 0) {
      await response.discard();
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'image response body is empty',
      );
    }

    session.beginNetworkAttemptProgress(response.rangeStart);
    var networkCursor = response.rangeStart;
    final _WebpNetworkFlowGate? flowGate =
        response.flowControl != ByteResponseFlowControl.none &&
                response.bodyAuthority == ByteResponseBodyAuthority.source
            ? _WebpNetworkFlowGate(
                session: session,
                cancel: cancel,
                capability: response.flowControl,
              )
            : null;

    if (start == 0 &&
        response.disposition == ByteResponseDisposition.durableImmutable &&
        response.totalLength != null) {
      session.beginResidentImmutableIngress(
        validators: response.validators,
        totalLength: response.totalLength!,
        validatorRequestUri: _requestUri,
        bodyAuthority: response.bodyAuthority,
      );
      var residentOffset = 0;
      final residentIterator = StreamIterator<List<int>>(response.bytes);
      try {
        while (await _moveNext(residentIterator, cancel)) {
          final chunk = residentIterator.current;
          if (chunk.isEmpty) continue;
          session.appendResidentImmutableIngress(residentOffset, chunk);
          residentOffset += chunk.length;
          networkCursor += chunk.length;
          session.advanceNetworkAttemptProgress(networkCursor);
          await Future<void>.delayed(Duration.zero);
        }
        session.sealResidentImmutableIngress();
        return;
      } catch (_) {
        await residentIterator.cancel();
        await session.reset();
        rethrow;
      }
    }

    if (fullBodyCatchup) {
      cancel?.beginRestartCost();
    }

    final writer = session.acquireWriter();
    var offset = session.committedLength;
    final iterator = StreamIterator<List<int>>(response.bytes);
    List<int> catchupRemainder = const <int>[];
    var restartCostBytes = 0;
    if (validatorlessRangeProbe) {
      var duplicatePrefixBytes = 0;
      try {
        catchupRemainder = await _verifyArtifactOverlap(
          iterator: iterator,
          probeStart: probeStart,
          preservedLength: preservedLength,
          cancel: cancel,
          flowGate: flowGate,
          networkCursor: () => networkCursor,
          onDuplicateBytes: (value) {
            duplicatePrefixBytes = value;
            networkCursor = probeStart + value;
            session.advanceNetworkAttemptProgress(networkCursor);
          },
        );
      } catch (error) {
        session.recordResume(
          restarted: true,
          strategy: 'validatorless-range-probe-rejected',
          playablePrefixPreserved: true,
          diagnostics: <String, Object?>{
            'resumeProbeStart': probeStart,
            'resumeProbeBytes': probeBytes,
            'resumeProbeStatusCode': response.statusCode,
            'resumeProbeAccepted': false,
            'duplicatePrefixBytes': duplicatePrefixBytes,
            if (providerValidatorMismatch) 'providerValidatorMismatch': true,
          },
        );
        await iterator.cancel();
        if (session.hasWriter) {
          await session.fail(writer, error);
        }
        rethrow;
      }
      networkCursor = probeStart + probeBytes + catchupRemainder.length;
      session.advanceNetworkAttemptProgress(networkCursor, force: true);
      session.recordResume(
        restarted: false,
        strategy: 'validatorless-range-probe',
        playablePrefixPreserved: true,
        diagnostics: <String, Object?>{
          'resumeProbeStart': probeStart,
          'resumeProbeBytes': probeBytes,
          'resumeProbeStatusCode': response.statusCode,
          'resumeProbeAccepted': true,
          'duplicatePrefixBytes': duplicatePrefixBytes,
          if (providerValidatorMismatch) 'providerValidatorMismatch': true,
        },
      );
    } else if (fullBodyCatchup) {
      var duplicatePrefixBytes = 0;
      try {
        catchupRemainder = await _verifyFullBodyPrefix(
          iterator: iterator,
          preservedLength: preservedLength,
          expectedChecksum: session.artifact.checksum,
          expectedTotalLength: response.totalLength,
          cancel: cancel,
          flowGate: flowGate,
          networkCursor: () => networkCursor,
          onDuplicateBytes: (value) {
            duplicatePrefixBytes = value;
            restartCostBytes = value;
            networkCursor = value;
            session.advanceNetworkAttemptProgress(networkCursor);
            cancel?.recordRestartCostBytes(restartCostBytes);
          },
        );
      } catch (error) {
        session.recordResume(
          restarted: true,
          strategy: 'full-body-prefix-catchup-aborted',
          playablePrefixPreserved: true,
          diagnostics: <String, Object?>{
            'duplicatePrefixBytes': duplicatePrefixBytes,
            if (providerValidatorMismatch) 'providerValidatorMismatch': true,
          },
        );
        await iterator.cancel();
        if (session.hasWriter) {
          await session.fail(writer, error);
        }
        rethrow;
      }
      session.recordResume(
        restarted: false,
        strategy: 'full-body-prefix-catchup',
        playablePrefixPreserved: true,
        diagnostics: <String, Object?>{
          'duplicatePrefixBytes': duplicatePrefixBytes,
        },
      );
      if (catchupRemainder.isNotEmpty) {
        restartCostBytes += catchupRemainder.length;
        networkCursor = preservedLength + catchupRemainder.length;
        session.advanceNetworkAttemptProgress(networkCursor, force: true);
        cancel?.recordRestartCostBytes(restartCostBytes);
      } else {
        networkCursor = preservedLength;
        session.advanceNetworkAttemptProgress(networkCursor, force: true);
      }
    }

    if (catchupRemainder.isNotEmpty) {
      flowGate?.addAuthoritativeBytes(catchupRemainder);
    }

    await session.bindResponse(
      validators: response.validators,
      totalLength: response.totalLength,
      validatorRequestUri: _requestUri,
    );
    final pending = BytesBuilder(copy: false);
    if (catchupRemainder.isNotEmpty) {
      pending.add(catchupRemainder);
    }
    var flushTarget = 16 * 1024;
    Future<void> flushPending() async {
      if (pending.length == 0) return;
      final bytes = pending.takeBytes();
      await session.append(writer, offset, bytes);
      offset += bytes.length;
      flushTarget = sourceProgressQuantumBytes;
    }
    try {
      while (true) {
        if (flowGate != null &&
            (flowGate.needsArtifactSynchronization || flowGate.blocked)) {
          await flushPending();
        }
        final available = await _moveNext(
          iterator,
          cancel,
          flowGate: flowGate,
          networkCursor: networkCursor,
        );
        if (!available) break;
        final chunk = iterator.current;
        if (chunk.isEmpty) continue;
        flowGate?.addAuthoritativeBytes(chunk);
        if (fullBodyCatchup) {
          restartCostBytes += chunk.length;
          cancel?.recordRestartCostBytes(restartCostBytes);
        }
        networkCursor += chunk.length;
        session.advanceNetworkAttemptProgress(networkCursor);
        pending.add(chunk);
        if (pending.length >= flushTarget) {
          await flushPending();
        }
      }
      await flushPending();
      if (offset <= 0) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'image response produced no bytes',
        );
      }
      await session.seal(
        writer,
        expectedLength: response.totalLength,
        expectedChecksum: expectedChecksum,
      );
      await session.promote();
    } catch (error) {
      // Preserve bytes already delivered by the transport so resume semantics
      // remain independent of the transport's arbitrary chunk size.
      try {
        await flushPending();
      } on Object {
        // The original failure remains authoritative; session.fail closes the
        // writer and records the recoverable partial state below.
      }
      await iterator.cancel();
      if (session.hasWriter) {
        await session.fail(writer, error);
      }
      rethrow;
    }
  }


  Future<List<int>> _verifyArtifactOverlap({
    required StreamIterator<List<int>> iterator,
    required int probeStart,
    required int preservedLength,
    required void Function(int duplicateBytes) onDuplicateBytes,
    CancelToken? cancel,
    _WebpNetworkFlowGate? flowGate,
    int Function()? networkCursor,
  }) async {
    final expectedLength = preservedLength - probeStart;
    if (expectedLength <= 0 || expectedLength > _validatorlessResumeProbeBytes) {
      throw const Failure(
        code: ErrorCode.resumeRejected,
        message: 'validatorless resume probe has an invalid overlap range',
      );
    }
    final expectedBuilder = BytesBuilder(copy: false);
    await for (final chunk in session.artifact.readChunks(
      chunkSize: _validatorlessResumeProbeBytes,
      start: probeStart,
      endExclusive: preservedLength,
    )) {
      expectedBuilder.add(chunk);
    }
    final expected = expectedBuilder.takeBytes();
    if (expected.length != expectedLength) {
      throw const Failure(
        code: ErrorCode.resumeRejected,
        message: 'existing playable partial changed during resume probe',
      );
    }

    var matched = 0;
    while (matched < expected.length) {
      final available = await _moveNext(
        iterator,
        cancel,
        flowGate: flowGate,
        networkCursor: networkCursor?.call() ?? 0,
      );
      if (!available) {
        throw const Failure(
          code: ErrorCode.resumeRejected,
          message: 'range response ended before the overlap boundary',
        );
      }
      final chunk = iterator.current;
      if (chunk.isEmpty) {
        continue;
      }
      final remaining = expected.length - matched;
      final take = chunk.length < remaining ? chunk.length : remaining;
      for (var index = 0; index < take; index++) {
        if (chunk[index] != expected[matched + index]) {
          throw const Failure(
            code: ErrorCode.resumeRejected,
            message: 'range overlap differs from the existing playable partial',
          );
        }
      }
      matched += take;
      onDuplicateBytes(matched);
      if (matched == expected.length) {
        return take == chunk.length
            ? const <int>[]
            : chunk.sublist(take);
      }
      await Future<void>.delayed(Duration.zero);
    }
    return const <int>[];
  }

  Future<List<int>> _verifyFullBodyPrefix({
    required StreamIterator<List<int>> iterator,
    required int preservedLength,
    required String expectedChecksum,
    required int? expectedTotalLength,
    required void Function(int duplicateBytes) onDuplicateBytes,
    CancelToken? cancel,
    _WebpNetworkFlowGate? flowGate,
    int Function()? networkCursor,
  }) async {
    if (preservedLength <= 0) {
      return const <int>[];
    }
    if (expectedChecksum.isEmpty) {
      throw const Failure(
        code: ErrorCode.resumeRejected,
        message: 'partial checksum unavailable; preserved the existing partial',
      );
    }
    if (expectedTotalLength != null && expectedTotalLength < preservedLength) {
      throw const Failure(
        code: ErrorCode.resumeRejected,
        message: 'full response is shorter than the existing partial',
      );
    }

    final checksum = Crc32();
    var remaining = preservedLength;
    var consumed = 0;
    while (remaining > 0) {
      final available = await _moveNext(
        iterator,
        cancel,
        flowGate: flowGate,
        networkCursor: networkCursor?.call() ?? 0,
      );
      if (!available) {
        throw const Failure(
          code: ErrorCode.resumeRejected,
          message: 'full response ended before the existing partial boundary',
        );
      }
      final chunk = iterator.current;
      if (chunk.isEmpty) {
        continue;
      }
      final take = chunk.length < remaining ? chunk.length : remaining;
      checksum.add(take == chunk.length ? chunk : chunk.sublist(0, take));
      remaining -= take;
      consumed += take;
      onDuplicateBytes(consumed);
      if (remaining == 0) {
        if (checksum.hex != expectedChecksum) {
          throw const Failure(
            code: ErrorCode.resumeRejected,
            message:
                'full response prefix differs from the existing playable partial',
          );
        }
        return take == chunk.length
            ? const <int>[]
            : chunk.sublist(take);
      }
      await Future<void>.delayed(Duration.zero);
    }
    return const <int>[];
  }


  Future<void> _deferCostlyFullBodyCatchupIfNeeded({
    required int preservedLength,
    CancelToken? cancel,
    ByteResponse? response,
    Map<String, Object?> diagnostics = const <String, Object?>{},
  }) async {
    final allowed = allowFullBodyCatchup?.call(preservedLength) ?? true;
    if (allowed) {
      return;
    }
    if (response != null) {
      await response.discard();
    }
    session.recordResume(
      restarted: true,
      strategy: 'full-body-prefix-catchup-deferred',
      playablePrefixPreserved: true,
      diagnostics: <String, Object?>{
        'deferredPrefixBytes': preservedLength,
        if (cancel != null) 'deferredPriority': cancel.priority,
        'duplicatePrefixBytes': 0,
        ...diagnostics,
      },
    );
    session.deferNetwork(reason: 'costly-full-body-catchup');
    throw DownloadCatchupDeferred(preservedLength: preservedLength);
  }

  Future<bool> _moveNext(
    StreamIterator<List<int>> iterator,
    CancelToken? cancel, {
    _WebpNetworkFlowGate? flowGate,
    int networkCursor = 0,
  }) async {
    if (flowGate != null) {
      await flowGate.waitBeforeRead(networkCursor: networkCursor);
    }
    if (cancel == null) {
      return iterator.moveNext();
    }
    cancel.throwIfCancelled();
    final result = await Future.any<Object>(<Future<Object>>[
      iterator.moveNext().then<Object>(_NextChunk.new),
      cancel.whenCancelled.then<Object>((_) => const _DownloadCancelled()),
    ]);
    if (result is _DownloadCancelled) {
      await iterator.cancel();
      cancel.throwIfCancelled();
    }
    return (result as _NextChunk).available;
  }

  Future<void> _discardIfCancelled(
    CancelToken? cancel,
    ByteResponse response,
  ) async {
    if (cancel?.cancelled ?? false) {
      await response.discard();
      cancel!.throwIfCancelled();
    }
  }

  Future<ByteResponse> _openRange(int start, CancelToken? cancel) {
    final controlled = transport is ControlledTransport
        ? transport as ControlledTransport
        : null;
    final range = ByteRange(start: start);
    if (controlled != null) {
      return controlled.openControlled(
        _requestUri,
        range: range,
        control: cancel,
      );
    }
    return transport.open(
      _requestUri,
      range: range,
    );
  }

  Future<ByteResponse> _open(int start, CancelToken? cancel) {
    final controlled = transport is ControlledTransport
        ? transport as ControlledTransport
        : null;
    final validators = session.resumeValidatorsFor(_requestUri);
    if (start > 0 && validators.canResume) {
      if (controlled != null) {
        return controlled.openControlled(
          _requestUri,
          range: ByteRange(start: start),
          validators: validators,
          control: cancel,
        );
      }
      return transport.open(
        _requestUri,
        range: ByteRange(start: start),
        validators: validators,
      );
    }
    if (controlled != null) {
      return controlled.openControlled(
        _requestUri,
        control: cancel,
      );
    }
    return transport.open(_requestUri);
  }
}

final class _WebpNetworkFlowGate {
  _WebpNetworkFlowGate({
    required this.session,
    required this.cancel,
    required this.capability,
  }) : _authoritativeCatchupFloor = session.committedLength;

  final DownloadSession session;
  final CancelToken? cancel;
  final ByteResponseFlowControl capability;
  final int _authoritativeCatchupFloor;
  static const Duration _consumerPacingInterval = Duration(milliseconds: 100);
  WebpFramePrefixTracker? _tracker;
  bool _initializing = false;
  bool _paused = false;

  bool get needsArtifactSynchronization =>
      (cancel?.flowTargetFrames ?? 0) > 0 && _tracker == null;

  bool get blocked {
    final control = cancel;
    final tracker = _tracker;
    return control != null &&
        tracker != null &&
        !tracker.unsupported &&
        control.flowBlockedAt(tracker.completedFrames);
  }

  Future<void> _ensureInitialized() async {
    if (_tracker != null || _initializing) return;
    _initializing = true;
    try {
      final tracker = WebpFramePrefixTracker();
      await for (final chunk in session.artifact.readChunks(
        endExclusive: session.committedLength,
      )) {
        tracker.add(chunk);
      }
      _tracker = tracker;
    } finally {
      _initializing = false;
    }
  }

  Future<void> waitBeforeRead({required int networkCursor}) async {
    final control = cancel;
    if (control == null || control.flowTargetFrames <= 0) return;
    // Resume/probe/full-body catch-up bytes only re-establish the already
    // authoritative physical partial. Frame credit must never pause the
    // network before that boundary, otherwise a restarted attempt can deadlock
    // behind its own existing frames.
    if (networkCursor < _authoritativeCatchupFloor) return;
    await _ensureInitialized();
    final tracker = _tracker;
    if (tracker == null || tracker.unsupported) return;
    if (!control.flowBlockedAt(tracker.completedFrames)) return;
    if (!_paused) {
      _paused = true;
      session.recordFlowControl(
        action: capability == ByteResponseFlowControl.streamBackpressure
            ? 'paused'
            : 'pseudo-paused',
        mode: capability.name,
        targetFrames: control.flowTargetFrames,
        completedFrames: tracker.completedFrames,
        networkCursor: networkCursor,
      );
    }
    if (capability == ByteResponseFlowControl.consumerPacing) {
      final creditGranted = await control.waitForFlowCreditOrTimeout(
        tracker.completedFrames,
        _consumerPacingInterval,
      );
      if (!creditGranted) {
        // Pseudo pause cannot promise upstream backpressure. Drain exactly one
        // downstream chunk per pacing interval to keep a single response alive
        // without turning unsupported pause into cancel/reopen churn.
        session.recordFlowControl(
          action: 'pseudo-drain',
          mode: capability.name,
          targetFrames: control.flowTargetFrames,
          completedFrames: tracker.completedFrames,
          networkCursor: networkCursor,
        );
        return;
      }
    } else {
      await control.waitForFlowCredit(tracker.completedFrames);
    }
    if (_paused) {
      _paused = false;
      session.recordFlowControl(
        action: capability == ByteResponseFlowControl.streamBackpressure
            ? 'resumed'
            : 'pseudo-resumed',
        mode: capability.name,
        targetFrames: control.flowTargetFrames,
        completedFrames: tracker.completedFrames,
        networkCursor: networkCursor,
      );
    }
  }

  void addAuthoritativeBytes(List<int> bytes) {
    _tracker?.add(bytes);
  }
}

final class _NextChunk {
  const _NextChunk(this.available);

  final bool available;
}

final class _DownloadCancelled {
  const _DownloadCancelled();
}
